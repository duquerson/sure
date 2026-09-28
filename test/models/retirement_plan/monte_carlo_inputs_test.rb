require "test_helper"

# What the Monte Carlo run is built from, how it is cached, and the job that
# runs it (#127, 8.3).
class RetirementPlan::MonteCarloInputsTest < ActiveJob::TestCase
  include EntriesTestHelper

  AS_OF = Date.new(2026, 3, 15)

  setup do
    @family = families(:dylan_family)
    @member = users(:family_member)
    RetirementPlan.where(user: @member).delete_all
    AccountShare.where(user: @member).delete_all
    account = Account.create!(family: @family, owner: @member, accountable: Depository.new,
                              name: "Checking #{SecureRandom.hex(3)}", currency: "USD", balance: 400_000)
    Balance.create!(account: account, date: AS_OF, balance: 400_000, currency: "USD")
    @plan = RetirementPlan.create!(user: @member, birth_year: 1980, end_age: 85, retirement_date: Date.new(2040, 1, 1),
                                   expected_annual_return: BigDecimal("0.05"))
    @plan.streams.create!(kind: "expense", name: "Living costs", annual_amount: 30_000)
  end

  test "the run uses the plan's own volatility, a seed fixed by the plan, and the plan's retirement year" do
    @plan.update!(return_volatility: BigDecimal("0.2")) # not the column default, so a hard-coded default fails
    mc = @plan.monte_carlo(as_of: AS_OF)

    assert_equal RetirementPlan::MONTE_CARLO_PATHS, mc.paths
    assert_equal 2040, mc.retirement_year
    assert_equal BigDecimal("0.2"), mc.volatility
    assert_equal @plan.monte_carlo_seed, mc.seed
    assert_equal @plan.monte_carlo_seed, RetirementPlan.find(@plan.id).monte_carlo_seed, "the seed is stable across loads"
    assert_not_equal @plan.monte_carlo_seed, RetirementPlan.create!(user: users(:family_admin)).monte_carlo_seed
  ensure
    RetirementPlan.where(user: users(:family_admin)).delete_all
  end

  test "in FIRE mode the run retires in the expected-returns year" do
    @plan.update!(mode: "fire")

    assert_equal @plan.solve(as_of: AS_OF).retirement_year, @plan.monte_carlo(as_of: AS_OF).retirement_year
  end

  test "the cache key is stable on a re-read and changes with every input" do
    base = @plan.monte_carlo_cache_key(as_of: AS_OF)
    assert_equal base, RetirementPlan.find(@plan.id).monte_carlo_cache_key(as_of: AS_OF)

    changes = {
      "a setting" => -> { @plan.update!(return_volatility: BigDecimal("0.2")) },
      "the target" => -> { @plan.update!(success_target: BigDecimal("0.8")) },
      "a stream" => -> { @plan.streams.first.update!(annual_amount: 31_000) },
      "the reference date" => -> { :as_of }
    }
    changes.each do |label, change|
      as_of = change.call == :as_of ? AS_OF + 1 : AS_OF
      assert_not_equal base, RetirementPlan.find(@plan.id).monte_carlo_cache_key(as_of: as_of), label
      base = RetirementPlan.find(@plan.id).monte_carlo_cache_key(as_of: AS_OF)
    end
  end

  test "the job writes the result under the key and broadcasts it to the plan's owner" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    key = @plan.monte_carlo_cache_key(as_of: AS_OF)
    # Only the section showing these inputs is replaced (CodeRabbit on #252):
    # an older run finishing late cannot overwrite a newer page's result.
    own_section = "#retirement-plan-monte-carlo[data-monte-carlo-key='#{key.split("/").last}']"
    Turbo::StreamsChannel.expects(:broadcast_replace_to).with([ @member, :retirement_plan ], has_entry(targets: own_section)).once

    RetirementPlan::MonteCarloJob.perform_now(@plan.id, AS_OF.iso8601)
    result = Rails.cache.read(key)

    assert_equal @plan.monte_carlo(as_of: AS_OF).success_rate, result[:success_rate]
    assert_equal RetirementPlan::MonteCarlo::PERCENTILES, result[:percentiles].keys
    assert_equal 5, result[:heatmap].size
  end

  test "a result already cached is not recomputed" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Rails.cache.write(@plan.monte_carlo_cache_key(as_of: AS_OF), { success_rate: 0.5 })
    RetirementPlan::MonteCarlo.any_instance.expects(:success_rate).never
    Turbo::StreamsChannel.stubs(:broadcast_replace_to)

    RetirementPlan::MonteCarloJob.perform_now(@plan.id, AS_OF.iso8601)
  end

  test "enqueueing twice for the same key runs one job" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    assert_enqueued_jobs 1, only: RetirementPlan::MonteCarloJob do
      2.times { @plan.enqueue_monte_carlo(as_of: AS_OF) }
    end
  end

  # CodeRabbit on #252: the confident year is a search over retirement years,
  # each a full run of every path, and only FIRE mode shows it.
  test "outside FIRE mode the result has no confident year and the search never runs" do
    RetirementPlan::MonteCarlo.any_instance.expects(:confident_year).never

    assert_nil @plan.monte_carlo_result(as_of: AS_OF)[:confident_year]
  end

  test "in FIRE mode the result carries the confident year for the plan's target" do
    @plan.update!(mode: "fire", success_target: BigDecimal("0.85"))
    RetirementPlan::MonteCarlo.any_instance.expects(:confident_year).with(BigDecimal("0.85")).returns(2039).once

    assert_equal 2039, @plan.monte_carlo_result(as_of: AS_OF)[:confident_year]
  end

  test "a finished run clears its pending marker" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Turbo::StreamsChannel.stubs(:broadcast_replace_to)
    marker = "#{@plan.monte_carlo_cache_key(as_of: AS_OF)}/pending"
    @plan.enqueue_monte_carlo(as_of: AS_OF)
    assert Rails.cache.exist?(marker)

    RetirementPlan::MonteCarloJob.perform_now(@plan.id, AS_OF.iso8601)

    assert_not Rails.cache.exist?(marker)
  end

  # Production Readiness Review and CodeRabbit on #252: a run that raises is
  # recorded for support and dropped rather than retried, since the same
  # inputs fail the same way, and its inputs are marked failed so the page
  # stops asking for them.
  test "a run that raises is recorded, discarded and marked failed" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Turbo::StreamsChannel.expects(:broadcast_replace_to).never
    RetirementPlan.any_instance.stubs(:monte_carlo_result).raises(ZeroDivisionError, "divided by 0")
    key = @plan.monte_carlo_cache_key(as_of: AS_OF)
    @plan.enqueue_monte_carlo(as_of: AS_OF)
    assert_not Rails.cache.exist?("#{key}/failed")

    assert_difference -> { DebugLogEntry.where(source: "RetirementPlan::MonteCarloJob", level: "error").count }, 1 do
      assert_nothing_raised { RetirementPlan::MonteCarloJob.perform_now(@plan.id, AS_OF.iso8601) }
    end

    entry = DebugLogEntry.where(source: "RetirementPlan::MonteCarloJob").last
    assert_equal @family, entry.family
    assert_equal({ "retirement_plan_id" => @plan.id, "as_of" => AS_OF.iso8601, "error_class" => "ZeroDivisionError" }, entry.metadata)
    assert Rails.cache.exist?("#{key}/failed")
    assert_not Rails.cache.exist?("#{key}/pending")
  end

  # CodeRabbit on #252: a plan saved while its run is in flight has new inputs
  # and a new key. The run's markers stay with the inputs it was started for.
  test "a run marks the inputs it started with, even if the plan changes while it runs" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Turbo::StreamsChannel.stubs(:broadcast_replace_to)
    started = @plan.monte_carlo_cache_key(as_of: AS_OF)
    @plan.enqueue_monte_carlo(as_of: AS_OF)
    RetirementPlan.any_instance.stubs(:monte_carlo_result).with do
      RetirementPlan.where(id: @plan.id).update_all(return_volatility: BigDecimal("0.3"))
      true
    end.raises(ZeroDivisionError, "divided by 0")

    RetirementPlan::MonteCarloJob.perform_now(@plan.id, AS_OF.iso8601)
    changed = RetirementPlan.find(@plan.id).monte_carlo_cache_key(as_of: AS_OF)

    assert_not_equal started, changed, "precondition: the edit changed the key"
    assert Rails.cache.exist?("#{started}/failed")
    assert_not Rails.cache.exist?("#{started}/pending")
    assert_not Rails.cache.exist?("#{changed}/failed")
  end

  test "a finished run clears the marker it started with, even if the plan changes while it runs" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    Turbo::StreamsChannel.stubs(:broadcast_replace_to)
    started = @plan.monte_carlo_cache_key(as_of: AS_OF)
    @plan.enqueue_monte_carlo(as_of: AS_OF)
    RetirementPlan.any_instance.stubs(:monte_carlo_result).with do
      RetirementPlan.where(id: @plan.id).update_all(return_volatility: BigDecimal("0.3"))
      true
    end.returns({ success_rate: 0.5 })

    RetirementPlan::MonteCarloJob.perform_now(@plan.id, AS_OF.iso8601)

    assert_not Rails.cache.exist?("#{started}/pending")
    assert_equal({ success_rate: 0.5 }, Rails.cache.read(started))
  end

  # CodeRabbit on #252: a marker left behind by a job that never queued would
  # hold the page on "calculating" with nothing running.
  test "a run that fails to enqueue leaves no pending marker" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    marker = @plan.monte_carlo_pending_key(as_of: AS_OF)

    RetirementPlan::MonteCarloJob.stubs(:perform_later).raises(RedisClient::CannotConnectError, "down")
    assert_raises(RedisClient::CannotConnectError) { @plan.enqueue_monte_carlo(as_of: AS_OF) }
    assert_not Rails.cache.exist?(marker)

    RetirementPlan::MonteCarloJob.stubs(:perform_later).returns(RetirementPlan::MonteCarloJob.new.tap { |job| job.successfully_enqueued = false })
    assert_equal false, @plan.enqueue_monte_carlo(as_of: AS_OF)
    assert_not Rails.cache.exist?(marker)
  end

  # Production Readiness Review of #252: each run is thousands of simulated
  # paths, so it yields to syncs and user-facing jobs.
  test "the job runs on the low-priority queue" do
    assert_equal "low_priority", RetirementPlan::MonteCarloJob.new.queue_name
  end
end

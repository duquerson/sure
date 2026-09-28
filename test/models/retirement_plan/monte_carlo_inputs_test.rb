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
    Turbo::StreamsChannel.expects(:broadcast_replace_to).with([ @member, :retirement_plan ], has_entry(target: "retirement-plan-monte-carlo")).once

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
end

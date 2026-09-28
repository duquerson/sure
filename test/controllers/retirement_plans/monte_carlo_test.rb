require "test_helper"

# The Monte Carlo result on the planner page (#127, 8.3).
class RetirementPlans::MonteCarloTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    RetirementPlan.where(user: @user).delete_all
    sign_in @user
    ensure_tailwind_build
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @plan = RetirementPlan.create!(user: @user, birth_year: 1980, end_age: 90, retirement_date: Date.new(2045, 1, 1),
                                   success_target: BigDecimal("0.9"))
  end

  def cached_result(success_rate: 0.93, confident_year: 2041)
    as_of = Date.current
    grid = RetirementPlan::MonteCarlo::RETURN_STEPS.map do |r|
      RetirementPlan::MonteCarlo::SAVINGS_STEPS.map { |s| { return_step: r, savings_step: s, success_rate: 0.5 } }
    end
    {
      as_of: as_of, retirement_year: 2045, success_rate: success_rate, stress_success_rate: 0.71,
      confident_year: confident_year, percentiles: RetirementPlan::MonteCarlo::PERCENTILES.index_with { [ 1.0, 2.0 ] },
      heatmap: grid, expected_annual_return: BigDecimal("0.05"), savings_rate: BigDecimal("0.2")
    }
  end

  test "a cached result is shown and no run is enqueued" do
    Rails.cache.write(@plan.monte_carlo_cache_key(as_of: Date.current), cached_result)

    assert_no_enqueued_jobs only: RetirementPlan::MonteCarloJob do
      get retirement_plan_url
    end

    assert_select "#retirement-plan-monte-carlo [data-success-rate='0.93']"
    assert_select "#retirement-plan-heatmap tbody tr", count: 5
    assert_select "[data-monte-carlo-pending]", count: 0
  end

  test "without a cached result one run is enqueued and the page says it is calculating, however often it is opened" do
    assert_enqueued_jobs 1, only: RetirementPlan::MonteCarloJob do
      2.times { get retirement_plan_url }
    end

    assert_select "#retirement-plan-monte-carlo [data-monte-carlo-pending]"
    # The layout subscribes to other streams, so assert this one by name.
    signed = Turbo::StreamsChannel.signed_stream_name([ @user, :retirement_plan ])
    assert_select "turbo-cable-stream-source[signed-stream-name='#{signed}']"
  end

  test "the run is enqueued for today's date and this plan" do
    get retirement_plan_url

    assert_enqueued_with job: RetirementPlan::MonteCarloJob, args: [ @plan.id, Date.current.iso8601 ]
  end

  test "a plan that cannot be simulated shows no Monte Carlo section and enqueues nothing" do
    @plan.update!(birth_year: nil)

    assert_no_enqueued_jobs do
      get retirement_plan_url
    end
    assert_select "#retirement-plan-monte-carlo", count: 0
  end

  test "in FIRE mode the confident year is shown, or that no year reaches the target" do
    @plan.update!(mode: "fire")
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("0"))
    Rails.cache.write(@plan.monte_carlo_cache_key(as_of: Date.current), cached_result)
    get retirement_plan_url
    assert_select "[data-confident-year='2041']"

    Rails.cache.write(@plan.monte_carlo_cache_key(as_of: Date.current), cached_result(confident_year: nil))
    get retirement_plan_url
    assert_select "[data-confident-year='none']"
  end

  test "the traditional mode shows no confident year" do
    Rails.cache.write(@plan.monte_carlo_cache_key(as_of: Date.current), cached_result)
    get retirement_plan_url

    assert_select "[data-confident-year]", count: 0
  end

  test "the volatility and confidence target are saved in their units" do
    patch retirement_plan_url, params: { retirement_plan: { return_volatility_percent: "15", success_target_percent: "85" } }

    assert_equal [ BigDecimal("0.15"), BigDecimal("0.85") ], @plan.reload.values_at(:return_volatility, :success_target)
  end

  test "a user without preview access is turned away before anything is enqueued" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    assert_no_enqueued_jobs do
      get retirement_plan_url
    end
    assert_redirected_to root_path
  end
end

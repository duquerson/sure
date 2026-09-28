require "test_helper"

# The full planner page and its streams (#127, 8.2).
class RetirementPlans::PlannerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @other = users(:family_member)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    RetirementPlan.where(user: [ @user, @other ]).delete_all
    sign_in @user
    ensure_tailwind_build
  end

  test "a user without preview access is turned away from the planner and its streams" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get retirement_plan_url
    assert_redirected_to root_path

    post retirement_plan_streams_url, params: { retirement_plan_stream: { kind: "expense", name: "x", annual_amount: 1 } }
    assert_redirected_to root_path
  end

  test "without a birth year the planner asks for one instead of showing a table" do
    RetirementPlan.create!(user: @user, retirement_date: Date.current.next_year(10))

    get retirement_plan_url

    assert_response :success
    assert_select "[data-planner-needs='birth_year']"
    assert_select "#retirement-planner-table", count: 0
  end

  test "a traditional plan shows a row for every year to the end age, and whether the money lasts" do
    RetirementPlan.create!(user: @user, birth_year: 1980, end_age: 90, retirement_date: Date.new(2045, 1, 1))

    get retirement_plan_url

    assert_select "#retirement-planner-table tbody tr", count: 2070 - Date.current.year + 1
    assert_select "#retirement-planner-table tbody tr[data-year='2045'][data-retired]"
    assert_select "[data-planner-outcome]"
  end

  test "a FIRE plan shows the earliest year on expected returns" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("0"))
    RetirementPlan.create!(user: @user, birth_year: 1980, mode: "fire")

    get retirement_plan_url

    assert_select "[data-planner-outcome='fire'][data-retirement-year='#{Date.current.year}']"
  end

  test "opening the planner seeds nothing and writes nothing" do
    RetirementPlan.create!(user: @user, birth_year: 1980, retirement_date: Date.new(2045, 1, 1))

    assert_no_difference [ "RetirementPlan::Stream.count" ] do
      get retirement_plan_url
    end
    assert_nil RetirementPlan.find_by!(user: @user).streams_seeded_on
  end

  test "saving the planner settings stores them in their units and seeds the streams once" do
    account = @user.family.accounts.create!(owner: @user, accountable: Depository.new, name: "Seed checking", currency: "USD", balance: 1)
    create_transaction(account: account, date: Date.current.beginning_of_month - 1.month, amount: 2_000)

    patch retirement_plan_url, params: { retirement_plan: {
      birth_year: "1980", end_age: "85", inflation_rate_percent: "2.5", mode: "fire"
    } }
    plan = RetirementPlan.find_by!(user: @user)

    assert_equal [ 1980, 85, BigDecimal("0.025"), "fire" ], [ plan.birth_year, plan.end_age, plan.inflation_rate, plan.mode ]
    assert plan.streams.exists?(source: "seeded_living_costs")
    assert_no_difference "RetirementPlan::Stream.count" do
      patch retirement_plan_url, params: { retirement_plan: { end_age: "86" } }
    end
  end

  test "an end age outside 50 to 120 is refused" do
    patch retirement_plan_url, params: { retirement_plan: { end_age: "30" } }

    assert_response :unprocessable_entity
  end

  test "a stream is added to the signed-in user's own plan" do
    assert_difference "RetirementPlan::Stream.count", 1 do
      post retirement_plan_streams_url, params: { retirement_plan_stream: {
        kind: "income", name: "State pension", annual_amount: "11000", start_year: "2047", indexed: "1"
      } }
    end

    stream = RetirementPlan.find_by!(user: @user).streams.sole
    assert_equal [ "income", BigDecimal("11000"), 2047, "manual" ], [ stream.kind, stream.annual_amount, stream.start_year, stream.source ]
  end

  test "an invalid stream is refused and nothing is written" do
    assert_no_difference "RetirementPlan::Stream.count" do
      post retirement_plan_streams_url, params: { retirement_plan_stream: { kind: "expense", name: "", annual_amount: "0" } }
    end

    assert_response :unprocessable_entity
  end

  test "another user's stream cannot be changed or deleted" do
    others = RetirementPlan.create!(user: @other).streams.create!(kind: "expense", name: "Theirs", annual_amount: 5)

    patch retirement_plan_stream_url(others), params: { retirement_plan_stream: { annual_amount: "1" } }
    assert_response :not_found
    delete retirement_plan_stream_url(others)
    assert_response :not_found

    assert_equal BigDecimal("5"), others.reload.annual_amount
  end

  test "a user's own stream can be changed and deleted" do
    stream = RetirementPlan.create!(user: @user).streams.create!(kind: "expense", name: "Mine", annual_amount: 5)

    patch retirement_plan_stream_url(stream), params: { retirement_plan_stream: { annual_amount: "7" } }
    assert_equal BigDecimal("7"), stream.reload.annual_amount

    assert_difference "RetirementPlan::Stream.count", -1 do
      delete retirement_plan_stream_url(stream)
    end
  end
end

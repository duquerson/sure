require "test_helper"

class RetirementPlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other = users(:family_member)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    RetirementPlan.where(user: [ @user, @other ]).delete_all
    sign_in @user
    ensure_tailwind_build
  end

  test "a user without preview access is turned away" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get edit_retirement_plan_url

    assert_redirected_to root_path
  end

  test "the form opens on the defaults when nothing is saved" do
    get edit_retirement_plan_url

    assert_response :success
    assert_select "input[name='retirement_plan[safe_withdrawal_rate_percent]'][value='4.0']"
    assert_select "input[name='retirement_plan[expected_annual_return_percent]'][value='5.0']"
  end

  test "saving writes the signed-in user's plan, in fractions, and nobody else's" do
    others = RetirementPlan.create!(user: @other, safe_withdrawal_rate: BigDecimal("0.03"))

    assert_difference "RetirementPlan.count", 1 do
      patch retirement_plan_url, params: { retirement_plan: {
        safe_withdrawal_rate_percent: "3.5", expected_annual_return_percent: "6",
        savings_rate_percent: "", retirement_date: "2045-06-30"
      } }
    end

    plan = RetirementPlan.find_by!(user: @user)
    assert_equal BigDecimal("0.035"), plan.safe_withdrawal_rate
    assert_equal BigDecimal("0.06"), plan.expected_annual_return
    assert_nil plan.savings_rate
    assert_equal Date.new(2045, 6, 30), plan.retirement_date
    assert_equal BigDecimal("0.03"), others.reload.safe_withdrawal_rate
  end

  test "a user id in the request is ignored" do
    patch retirement_plan_url, params: { retirement_plan: { user_id: @other.id, safe_withdrawal_rate_percent: "5" } }

    assert_equal @user, RetirementPlan.find_by!(safe_withdrawal_rate: BigDecimal("0.05")).user
    assert_nil RetirementPlan.find_by(user: @other)
  end

  test "an invalid withdrawal rate is refused and nothing is written" do
    assert_no_difference "RetirementPlan.count" do
      patch retirement_plan_url, params: { retirement_plan: { safe_withdrawal_rate_percent: "0" } }
    end

    assert_response :unprocessable_entity
  end

  test "the plan page shows the FI card, and the portfolio shows the section" do
    get plan_url
    assert_response :success
    assert_select "#retirement-plan-summary"

    get portfolio_url
    assert_response :success
    assert_select "[data-section-key='retirement'] #retirement-plan-summary"
  end

  test "the card shows the FI number worked out from the viewer's spending" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("1000"))
    IncomeStatement.any_instance.stubs(:median_income).returns(BigDecimal("3000"))
    RetirementPlan.create!(user: @user, safe_withdrawal_rate: BigDecimal("0.04"))

    get plan_url

    assert_select "#retirement-plan-summary [data-fi-number]", text: /\$300,000/
  end

  test "with no spending to go on, the card asks for it instead of showing a figure" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("0"))
    IncomeStatement.any_instance.stubs(:median_income).returns(BigDecimal("0"))

    get plan_url

    assert_select "#retirement-plan-summary [data-fi-number]", count: 0
    assert_select "#retirement-plan-summary", text: /#{Regexp.escape(I18n.t("retirement_plans.summary.no_expenses"))}/
  end

  test "past independence the bar is full and the figure says how far past" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("1"))
    IncomeStatement.any_instance.stubs(:median_income).returns(BigDecimal("0"))
    RetirementPlan::Projection.any_instance.stubs(:current_assets).returns(BigDecimal("336"))

    get plan_url

    assert_select "#retirement-plan-summary [data-fi-bar][style*='inline-size: 100']"
    assert_select "#retirement-plan-summary [data-fi-progress]", text: /112%/
  end

  test "a saved portfolio order from before the section existed still shows it" do
    @user.update_section_preferences("portfolio", order: Portfolio::SectionRegistry::KEYS - [ "retirement" ], collapsed: {})

    get portfolio_url

    assert_select "[data-section-key='retirement']"
  end

  test "the section can be dragged and collapsed like the others" do
    patch update_preferences_portfolio_path, params: { preferences: {
      portfolio_section_order: [ "retirement", "kpis" ],
      portfolio_collapsed_sections: { "retirement" => "true" }
    } }, as: :json

    assert_response :ok
    @user.reload
    assert_equal "retirement", @user.section_order("portfolio").first
    assert @user.section_collapsed?("portfolio", "retirement")
  end
end

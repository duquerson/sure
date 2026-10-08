require "test_helper"

# #131, 12.1. The three portfolio tools report the figures the portfolio pages
# show the same user (InvestmentStatement for that user), and count only the
# accounts that user includes in their finances.
class Assistant::Function::PortfolioToolsTest < ActiveSupport::TestCase
  include PortfolioReturnsTestHelper

  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @family = @admin.family
    @day_one = Date.current - 5.days
    @day_two = Date.current - 4.days

    # The member's brokerage, shared with the admin. Whether the admin counts
    # it is the share's include_in_finances flag.
    @shared = create_portfolio_account(family: @family, name: "Member brokerage", balance: 2_310)
    @shared.update!(owner: @member)
    @share = @shared.account_shares.create!(user: @admin, permission: "read_only", include_in_finances: true)
    lay_balance account: @shared, date: @day_one, opening: 1_000, closing: 1_100, market_flow: 100
    lay_balance account: @shared, date: @day_two, opening: 1_100, closing: 2_310, cash_flow: 1_000, market_flow: 210
    deposit account: @shared, date: @day_two, amount: 1_000
    income_trade account: @shared, date: @day_two, amount: 25
  end

  # ------------------------------------------------------- same figures

  test "performance reports the investment statement's figures for the same user and period" do
    result = call(Assistant::Function::GetPortfolioPerformance, { "period" => "last_30_days" })
    expected = InvestmentStatement.new(@family, user: @admin).performance(period: Period.from_key("last_30_days"))

    assert result[:available]
    assert_equal expected.time_weighted_return.to_d.round(6).to_f, result[:time_weighted_return][:value]
    assert_equal expected.drivers.to_h[:value_close].to_d.round(2).to_f, result[:drivers][:value_close][:amount]
    assert_equal expected.rate_missing?, result[:rate_missing]
  end

  test "allocation reports the investment statement's segments for the same user" do
    result = call(Assistant::Function::GetPortfolioAllocation, { "by" => "account" })
    expected = InvestmentStatement.new(@family, user: @admin).allocation_by("account")

    assert_equal expected.map(&:id).sort, result[:segments].map { |s| s[:id] }.sort
    segment = result[:segments].find { |s| s[:id] == @shared.id }
    assert_equal expected.find { |s| s.id == @shared.id }.weight.to_d.round(2).to_f, segment[:weight_percent]
  end

  test "income reports the statement's income for the same user and period" do
    result = call(Assistant::Function::GetIncomeSummary, { "period" => "last_30_days" })
    expected = InvestmentStatement.new(@family, user: @admin).performance(period: Period.from_key("last_30_days")).income

    assert result[:available]
    assert_equal expected[:total].to_d.round(2).to_f, result[:total][:amount]
    assert_operator result[:total][:amount], :>=, 25
  end

  # ---------------------------------------- included_in_finances_for(user)

  # Measured as a delta: the same account, the same history, and only the
  # share's include_in_finances flag changed.
  test "an account shared without include_in_finances leaves every tool's figures" do
    with_shared = figures

    @share.update!(include_in_finances: false)
    without_shared = figures

    assert_includes with_shared[:allocation_ids], @shared.id
    assert_not_includes without_shared[:allocation_ids], @shared.id
    assert_operator with_shared[:value_close], :>, without_shared[:value_close].to_f
    assert_in_delta with_shared[:income] - 25, without_shared[:income], 0.001
  end

  # The owner always counts their own account, whatever they share.
  test "the owner's own figures include their account" do
    member_ids = call(Assistant::Function::GetPortfolioAllocation, { "by" => "account" }, @member)[:segments].map { |s| s[:id] }

    assert_includes member_ids, @shared.id
  end

  # ------------------------------------------------------- what is refused

  test "a period with no investment history says so instead of failing" do
    result = call(Assistant::Function::GetPortfolioPerformance, { "period" => "last_30_days" }, users(:empty))

    assert_equal false, result[:available]
    assert_match(/No investment/, result[:message])
  end

  test "an unknown period, a half range or a bad date is an error, not a default" do
    tool = Assistant::Function::GetPortfolioPerformance

    assert_equal "invalid_period", call(tool, { "period" => "all_time" })[:error]
    assert_equal "invalid_date", call(tool, { "start_date" => @day_one.iso8601 })[:error]
    assert_equal "invalid_date", call(tool, { "start_date" => "2026-02-30", "end_date" => "2026-03-01" })[:error]
    assert_equal "invalid_date", call(tool, { "start_date" => @day_two.iso8601, "end_date" => @day_one.iso8601 })[:error]
  end

  test "a custom range is the period reported" do
    result = call(Assistant::Function::GetPortfolioPerformance, { "start_date" => @day_one.iso8601, "end_date" => @day_two.iso8601 })

    assert_equal @day_one, result[:period][:start_date]
    assert_equal @day_two, result[:period][:end_date]
  end

  test "look_through is refused on a dimension it does not apply to" do
    result = call(Assistant::Function::GetPortfolioAllocation, { "by" => "account", "look_through" => true })

    assert_equal "invalid_look_through", result[:error]
  end

  # R13: a missing rate withholds the return; the tool must not report 0.
  test "a withheld return is reported as null with rate_missing, not as zero" do
    Portfolio::Performance.any_instance.stubs(:rate_missing?).returns(true)
    Portfolio::Performance.any_instance.stubs(:time_weighted_return).returns(nil)

    result = call(Assistant::Function::GetPortfolioPerformance, { "period" => "last_30_days" })

    assert result[:rate_missing]
    assert_nil result[:time_weighted_return]
  end

  # ------------------------------------------------------------ registry

  test "the tools are offered only to a user with preview features, in chat and over MCP" do
    names = ->(user) { Assistant.function_classes(user).map(&:name) }
    tools = %w[get_portfolio_performance get_portfolio_allocation get_income_summary]

    @admin.update!(preferences: (@admin.preferences || {}).merge("preview_features_enabled" => false))
    assert_empty tools & names.call(@admin)

    @admin.update!(preferences: (@admin.preferences || {}).merge("preview_features_enabled" => true))
    assert_equal tools.sort, (tools & names.call(@admin)).sort
  end

  private
    def call(tool, params = {}, user = @admin)
      tool.new(user).call(params)
    end

    def figures
      performance = call(Assistant::Function::GetPortfolioPerformance, { "period" => "last_30_days" })
      income = call(Assistant::Function::GetIncomeSummary, { "period" => "last_30_days" })
      allocation = call(Assistant::Function::GetPortfolioAllocation, { "by" => "account" })

      {
        value_close: performance.dig(:drivers, :value_close, :amount).to_f,
        income: income.dig(:total, :amount).to_f,
        allocation_ids: allocation[:segments].map { |s| s[:id] }
      }
    end
end

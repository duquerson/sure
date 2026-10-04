require "test_helper"

class UI::Account::ChartTest < ViewComponent::TestCase
  setup do
    @account = accounts(:investment)
    @account.holdings.destroy_all
  end

  test "renders positive gains with explicit plus sign" do
    create_holding(cost_basis: 90)

    render_inline(UI::Account::Chart.new(account: @account, view: "gains"))

    assert_text "+$100.00"
  end

  # The all-time period is widened to the account's own history start, which is
  # right for an account that began after the family did. It must not be widened
  # to a start AFTER the period's end: `Period#initialize` validates the range
  # and raises, so the chart 500s rather than drawing anything.
  #
  # Reachable whenever `history_start_date` is in the future -- a scheduled
  # opening anchor, a valuation dated ahead, a provider backfill that lands
  # tomorrow. The fork's `Account#chart_period` guarded this with
  # `start_date > Date.current`; the generalised version adopted from upstream
  # in the A1 sync did not carry the guard, and the 8 tests on `chart_period`
  # kept passing because the component had stopped calling it.
  test "an account whose history starts after the period ends still renders" do
    @account.update!(name: "Future start")
    Account.any_instance.stubs(:history_start_date).returns(Date.current + 30)

    component = UI::Account::Chart.new(account: @account, period: Period.from_key("all_time"), view: "balance")

    period = component.send(:period)

    assert_operator period.start_date, :<=, period.end_date,
                    "a period whose start is after its end cannot be built at all"
  end

  test "does not sign non-gains views" do
    component = UI::Account::Chart.new(account: @account, view: "balance")

    assert_equal @account.balance_money.format, component.view_balance_display
    refute component.view_balance_display.start_with?("+")
  end

  test "negative gains keep plain money formatting" do
    create_holding(cost_basis: 110)

    component = UI::Account::Chart.new(account: @account, view: "gains")

    assert_equal "-$100.00", component.view_balance_display
  end

  test "converted amount is signed like the main indicator for foreign-currency accounts" do
    @account.update!(currency: "EUR")
    create_holding(cost_basis: 90)
    ExchangeRate.create!(date: Date.current, from_currency: "EUR", to_currency: "USD", rate: 1.1)

    component = UI::Account::Chart.new(account: @account, view: "gains")

    assert_equal "+€100.00", component.view_balance_display
    assert_equal "+$110.00", component.converted_balance_display
  end

  test "scopes all_time period to account history_start_date when history postdates family oldest entry date" do
    account_opening = 60.days.ago.to_date
    @account.stubs(:history_start_date).returns(account_opening)

    family_oldest = 5.years.ago.to_date
    all_time_period = Period.new(key: "all_time", start_date: family_oldest, end_date: Date.current)

    component = UI::Account::Chart.new(account: @account, period: all_time_period)

    assert_equal "all_time", component.period.key
    assert_equal account_opening, component.period.start_date
    assert_equal Date.current, component.period.end_date
    assert_equal "1 day", component.period.interval
  end

  test "does not clamp non-all_time periods even if account opening postdates period start" do
    account_opening = 10.days.ago.to_date
    @account.stubs(:history_start_date).returns(account_opening)

    last_30_days = Period.from_key("last_30_days")
    component = UI::Account::Chart.new(account: @account, period: last_30_days)

    assert_equal "last_30_days", component.period.key
    assert_equal 30.days.ago.to_date, component.period.start_date
  end

  test "unlinked account with trade 2 years ago clamps all_time to 2 years with 1 week interval" do
    two_years_ago = 2.years.ago.to_date
    @account.stubs(:history_start_date).returns(two_years_ago)

    family_oldest = 10.years.ago.to_date
    all_time_period = Period.new(key: "all_time", start_date: family_oldest, end_date: Date.current)

    component = UI::Account::Chart.new(account: @account, period: all_time_period)

    assert_equal "all_time", component.period.key
    assert_equal two_years_ago, component.period.start_date
    assert_equal "1 week", component.period.interval
  end

  test "unlinked account with trade 10 years ago clamps all_time to 10 years with 1 month interval" do
    ten_years_ago = 10.years.ago.to_date
    @account.stubs(:history_start_date).returns(ten_years_ago)

    family_oldest = 15.years.ago.to_date
    all_time_period = Period.new(key: "all_time", start_date: family_oldest, end_date: Date.current)

    component = UI::Account::Chart.new(account: @account, period: all_time_period)

    assert_equal "all_time", component.period.key
    assert_equal ten_years_ago, component.period.start_date
    assert_equal "1 month", component.period.interval
  end

  test "unlinked account on 5Y period does not clamp period and shows full timeframe comparison" do
    two_years_ago = 2.years.ago.to_date
    @account.stubs(:history_start_date).returns(two_years_ago)

    last_5_years = Period.from_key("last_5_years")
    component = UI::Account::Chart.new(account: @account, period: last_5_years)

    assert_equal "last_5_years", component.period.key
    assert_equal 5.years.ago.to_date, component.period.start_date
    assert_equal "1 week", component.period.interval

    last_10_years = Period.from_key("last_10_years")
    ten_year_component = UI::Account::Chart.new(account: @account, period: last_10_years)
    assert_equal "last_10_years", ten_year_component.period.key
    assert_equal 10.years.ago.to_date, ten_year_component.period.start_date
    assert_equal "1 month", ten_year_component.period.interval

    # When series covers full period (unlinked account showing 0 baseline)
    mock_series = Series.new(
      start_date: 5.years.ago.to_date,
      end_date: Date.current,
      interval: "1 month",
      values: [
        Series::Value.new(date: 5.years.ago.to_date, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(100, "USD"))
      ],
      favorable_direction: @account.favorable_direction
    )
    component.stubs(:series).returns(mock_series)
    assert_equal "vs. 5 years ago", component.comparison_label
  end

  test "linked account on 5Y period with trimmed history shows vs available history comparison" do
    two_years_ago = 2.years.ago.to_date
    @account.stubs(:history_start_date).returns(two_years_ago)

    last_5_years = Period.from_key("last_5_years")
    component = UI::Account::Chart.new(account: @account, period: last_5_years)

    # Series normalized to 2 years ago (trimmed from 5 years ago)
    mock_series = Series.new(
      start_date: two_years_ago,
      end_date: Date.current,
      interval: "1 month",
      values: [
        Series::Value.new(date: two_years_ago, date_formatted: "", value: Money.new(0, "USD")),
        Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(100, "USD"))
      ],
      favorable_direction: @account.favorable_direction
    )
    component.stubs(:series).returns(mock_series)
    assert_equal I18n.t("UI.account.chart.vs_available_history"), component.comparison_label
  end

  test "empty account with nil history_start_date leaves all_time period unchanged" do
    @account.stubs(:history_start_date).returns(nil)

    family_oldest = 5.years.ago.to_date
    all_time_period = Period.new(key: "all_time", start_date: family_oldest, end_date: Date.current)

    component = UI::Account::Chart.new(account: @account, period: all_time_period)

    assert_equal "all_time", component.period.key
    assert_equal family_oldest, component.period.start_date
  end

  # #300 stacking: `all_time` from `Period.from_key` is now family-scoped to the
  # earliest Transaction/Trade. The account chart's clamp (which keys off
  # `p.start_date`) must fire the same way when the account's own history begins
  # AFTa that family anchor -- it narrows to the account's own start, not the
  # family's, and the key is preserved. Proves the clamp path still stacks with
  # the new anchor rather than being shadowed by it.
  test "all_time family anchor is clamped to the account's own start when it postdates it" do
    Current.session = Session.create!(user: users(:family_admin))
    account_start = 10.days.ago.to_date
    @account.stubs(:history_start_date).returns(account_start)

    family_all_time = Period.from_key("all_time")
    component = UI::Account::Chart.new(account: @account, period: family_all_time)

    assert_equal "all_time", component.period.key
    assert_equal account_start, component.period.start_date,
      "the account's own history start must win when it postdates the family anchor"
    assert_equal family_all_time.end_date, component.period.end_date
  ensure
    Current.session = nil
  end

  # #300 stacking (the other side): an account whose history is OLDER than the
  # family anchor is not widened -- the account chart keeps the family-scoped
  # start rather than clamping back to the account's much earlier date.
  test "all_time family anchor is not clamped when the account history predates it" do
    Current.session = Session.create!(user: users(:family_admin))
    account_start = 2.years.ago.to_date
    @account.stubs(:history_start_date).returns(account_start)

    family_all_time = Period.from_key("all_time")
    component = UI::Account::Chart.new(account: @account, period: family_all_time)

    assert_equal "all_time", component.period.key
    assert_equal family_all_time.start_date, component.period.start_date,
      "an account whose history predates the family anchor keeps the family start"
  ensure
    Current.session = nil
  end

  private
    # 10 shares at $100 market price; gain = 1000 - cost_basis * 10
    def create_holding(cost_basis:)
      Holding.create!(
        account: @account,
        security: securities(:aapl),
        date: Date.current,
        qty: 10,
        price: 100,
        amount: 1000,
        currency: @account.currency,
        cost_basis: cost_basis
      )
    end
end

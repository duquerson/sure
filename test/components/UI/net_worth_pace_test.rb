require "test_helper"

class UI::NetWorthPaceTest < ViewComponent::TestCase
  setup do
    @balance_sheet = BalanceSheet.new(families(:empty))
    @period = Period.custom(start_date: Date.current - 29, end_date: Date.current)
  end

  test "renders velocity and momentum with their signs" do
    stub_pace(velocity: 1_234.5, momentum: -120)

    render_inline component

    assert_selector "[data-net-worth-pace] dt", text: "Velocity"
    assert_selector "[data-net-worth-pace] dd", text: "+$1,234.50 / month"
    assert_selector "[data-net-worth-pace] dt", text: "Momentum"
    assert_selector "[data-net-worth-pace] dd", text: "−$120.00 / month"
  end

  test "labels are translated" do
    stub_pace(velocity: 1_234.5, momentum: -120)

    I18n.with_locale(:de) { render_inline component }

    assert_selector "[data-net-worth-pace] dt", text: "Tempo"
    assert_selector "[data-net-worth-pace] dt", text: "Dynamik"
    assert_selector "dd", text: "/ Monat", count: 2
    assert_no_selector "dt", text: "Velocity"
  end

  test "a rising pace shows a plus on momentum, a falling one a minus on velocity" do
    stub_pace(velocity: -50, momentum: 75)

    render_inline component

    assert_selector "dd", text: "−$50.00 / month"
    assert_selector "dd", text: "+$75.00 / month"
  end

  test "an amount that rounds to zero carries no sign" do
    stub_pace(velocity: 0, momentum: -0.004)

    render_inline component

    assert_selector "dd", text: "$0.00 / month", count: 2
    assert_no_text "−$0.00"
    assert_no_text "+$0.00"
  end

  test "momentum is left out when it cannot be read, velocity stays" do
    stub_pace(velocity: 500, momentum: nil)

    render_inline component

    assert_selector "dd", text: "+$500.00 / month"
    assert_no_selector "dt", text: "Momentum"
  end

  test "renders nothing when there is no velocity" do
    stub_pace(velocity: nil, momentum: nil)

    render_inline component

    assert_no_selector "[data-net-worth-pace]"
    assert_not component.render?
  end

  private
    def component
      UI::NetWorthPace.new(balance_sheet: @balance_sheet, period: @period)
    end

    def stub_pace(velocity:, momentum:)
      money = ->(amount) { amount && Money.new(amount, "USD") }
      BalanceSheet::NetWorthVelocity.any_instance.stubs(:velocity).returns(money.call(velocity))
      BalanceSheet::NetWorthVelocity.any_instance.stubs(:momentum).returns(money.call(momentum))
    end
end

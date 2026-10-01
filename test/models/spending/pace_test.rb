require "test_helper"

class Spending::PaceTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # June 2026 has 30 days, so the elapsed fraction on day N is N/30 and every
  # boundary below is an exact decimal, not a float that merely rounds well.
  START = Date.new(2026, 6, 1)
  FINISH = Date.new(2026, 6, 30)

  def budget(spent:, budgeted: 1000)
    OpenStruct.new(
      start_date: START,
      end_date: FINISH,
      budgeted_spending: budgeted&.to_d,
      actual_spending: spent.to_d
    )
  end

  def pace(spent:, day:, budgeted: 1000)
    Spending::Pace.for(budget(spent: spent, budgeted: budgeted), on: Date.new(2026, 6, day))
  end

  # The approaching threshold is a 5% tolerance on the straight-line pace:
  # on day 15 (half the month) a 1,000 budget allows 500 of spend, so 525 is
  # exactly 1.05x pace. At the line is on track; a cent past it is approaching.
  test "exactly 5 percent ahead of pace is still on track" do
    assert_equal :on_track, pace(spent: "525.00", day: 15).status
  end

  test "a cent past 5 percent ahead of pace is approaching" do
    assert_equal :approaching, pace(spent: "525.01", day: 15).status
  end

  test "spending below the straight-line pace is on track" do
    assert_equal :on_track, pace(spent: "100", day: 15).status
  end

  # The same 300 spent is on pace on day 9 (9/30 = 30%) and ahead of it a day
  # earlier (8/30 = 26.7%), so the elapsed fraction, not just the spend, moves
  # the status.
  test "the same spend flips from on track to approaching as the month is less elapsed" do
    assert_equal :on_track, pace(spent: "300", day: 9).status
    assert_equal :approaching, pace(spent: "300", day: 8).status
  end

  # Over means the whole budget is spent, not that the pace is high.
  test "spending exactly the full budget on the last day is on track, not over" do
    assert_equal :on_track, pace(spent: "1000", day: 30).status
  end

  test "a cent over the full budget is over, even on the last day" do
    assert_equal :over, pace(spent: "1000.01", day: 30).status
  end

  test "spending the full budget early is approaching until it is exceeded" do
    assert_equal :approaching, pace(spent: "1000", day: 15).status
    assert_equal :over, pace(spent: "1000.01", day: 15).status
  end

  test "exposes the fractions and the projection the page shows" do
    result = pace(spent: "400", day: 10)

    assert_equal 10, result.elapsed_days
    assert_equal 30, result.total_days
    assert_equal Rational(1, 3), result.elapsed_fraction
    assert_equal Rational(2, 5), result.spent_fraction
    assert_equal 1200.to_d, result.projected_spend
    assert_equal 1000.to_d, result.budgeted
    assert_equal 400.to_d, result.spent
  end

  test "no budget means no pace" do
    assert_nil Spending::Pace.for(nil, on: Date.new(2026, 6, 15))
  end

  test "a budget that has not been set up means no pace" do
    assert_nil pace(spent: "400", day: 15, budgeted: nil)
  end

  test "a zero budget means no pace and does not divide by zero" do
    assert_nil pace(spent: "400", day: 15, budgeted: 0)
  end

  test "a date after the period counts the whole period as elapsed" do
    result = Spending::Pace.for(budget(spent: 900), on: Date.new(2026, 7, 20))

    assert_equal 30, result.elapsed_days
    assert_equal :on_track, result.status
  end

  test "a date before the period counts as the first day rather than raising" do
    result = Spending::Pace.for(budget(spent: 10), on: Date.new(2026, 5, 20))

    assert_equal 1, result.elapsed_days
  end

  # Wiring check against a real Budget: actual_spending must be the figure the
  # budget page shows, so the pace cannot disagree with the budget it cites.
  test "reads spent from the real budget's actual spending" do
    month = Date.new(2024, 3, 1)
    budget = Budget.create!(family: families(:dylan_family), start_date: month, end_date: month.end_of_month,
                            budgeted_spending: 1000, expected_income: 0, currency: "USD")
    before = Spending::Pace.for(budget, on: month + 9).spent

    create_transaction(date: month + 3, amount: 250)
    result = Spending::Pace.for(Budget.find(budget.id), on: month + 9)

    assert_equal 250, result.spent - before
  end
end

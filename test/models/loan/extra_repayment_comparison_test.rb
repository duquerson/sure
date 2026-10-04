require "test_helper"

class Loan::ExtraRepaymentComparisonTest < ActiveSupport::TestCase
  setup do
    start_date = Date.current
    @account = Account.create!(
      family: families(:dylan_family),
      name: "Comparison Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage", interest_rate: 3.5, term_months: 360, rate_type: "fixed", start_date: start_date
      )
    )
    @account.entries.create!(
      name: "Starting balance", amount: 500000, currency: "USD", date: start_date,
      entryable: Valuation.new(kind: "opening_anchor")
    )
    @loan = @account.loan
  end

  test "with no amount only the baseline is built and charted" do
    comparison = @loan.extra_repayment_comparison(amount: nil)

    assert_nil comparison.extra
    assert_not comparison.extra_applicable?
    assert_nil comparison.months_sooner
    assert_nil comparison.interest_saved
    assert comparison.chart_payload.present?, "an on-schedule loan still gets its baseline chart"
    assert_not comparison.chart_payload.key?(:extra_projection)
  end

  test "a blank amount is the same as no amount" do
    assert_nil @loan.extra_repayment_comparison(amount: "").extra
  end

  test "with an amount both projections share one as_of and the figures compare them" do
    as_of = Date.current
    comparison = @loan.extra_repayment_comparison(amount: "200", as_of: as_of)

    assert_equal as_of, comparison.baseline.as_of
    assert_equal as_of, comparison.extra.as_of
    assert comparison.extra_applicable?
    assert_equal comparison.baseline.payment_count - comparison.extra.payment_count, comparison.months_sooner
    assert_equal Money.new(comparison.baseline.total_interest.amount - comparison.extra.total_interest.amount, "USD"),
      comparison.interest_saved
    assert_equal comparison.extra.payoff_date.iso8601, comparison.chart_payload[:extra_payoff_date]
    assert_equal "Modeling an extra $200.00 per month", comparison.chart_payload[:extra_payment_label]
  end
end

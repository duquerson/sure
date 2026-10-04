class Loan
  # What the Extra repayments tab shows (#304): the loan's projection with an
  # extra amount paid each month, measured against the same projection
  # WITHOUT it. Both projections are built once, on one `as_of`, so the cards
  # and the chart can never quote figures from two different "todays".
  #
  # Not persisted, and never writes: like every projection it is computed live
  # from the account's current balance.
  class ExtraRepaymentComparison
    attr_reader :loan, :amount, :as_of

    # `amount` is the raw, request-validated monthly figure, or nil for "no
    # extra entered yet" -- in which case only the baseline is drawn.
    def initialize(loan, amount: nil, as_of: Date.current)
      @loan = loan
      @amount = amount.presence
      @as_of = as_of
    end

    # The loan if nothing extra is paid.
    def baseline
      @baseline ||= PayoffProjection.new(loan, as_of: as_of)
    end

    # The loan with the extra paid each month; nil when no amount was entered.
    def extra
      return nil if amount.nil?
      @extra ||= loan.payoff_projection_with_extra(amount: amount, as_of: as_of)
    end

    def extra_applicable?
      extra.present? && extra.applicable?
    end

    # How many payments sooner the extra clears the loan than the baseline.
    def months_sooner
      extra&.months_sooner_than(baseline)
    end

    # Interest the extra saves against not paying it, as Money.
    def interest_saved
      saved = extra&.interest_saved_versus(baseline)
      saved && Money.new(saved, baseline.currency)
    end

    # The chart, baseline always and the extra line beside it when there is
    # one. Not gated on divergence: an on-schedule loan is exactly where the
    # baseline is needed to compare an extra payment against.
    def chart_payload
      @chart_payload ||= loan.payoff_chart_payload(
        projection: baseline,
        extra_projection: extra,
        extra_payment_amount: amount,
        extra_payment_frequency: (amount && "monthly"),
        require_divergence: false,
        as_of: as_of
      )
    end

    # True when the current repayment never clears the loan, so there is no
    # baseline to draw; the tab says so instead of showing an empty chart.
    def baseline_does_not_converge?
      loan.amortization_schedule.amortizable? &&
        baseline.current_balance.amount.positive? &&
        !baseline.converged?
    end
  end
end

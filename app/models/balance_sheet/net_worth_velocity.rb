# How fast net worth is moving over a period (velocity, per month) and how that
# pace compares with the period immediately before it (momentum).
#
# Both are read from `BalanceSheet#net_worth_series`: the series the dashboard
# chart is drawn from, so the figures can never disagree with the trend printed
# above them, and it already honours the viewer's account visibility. Amounts
# are BigDecimal throughout and are not rounded here; `Money#format` rounds for
# display, which is the only rounding point.
#
# Velocity and momentum are withheld (nil) rather than guessed when the family's
# history does not cover the whole window they compare. Net worth reads zero
# before the first entry, so a window that starts earlier than the data would
# look like a flat stretch, or like growth from nothing when an account is added
# mid-period. Neither is a pace worth reporting.
class BalanceSheet::NetWorthVelocity
  DAYS_PER_MONTH = BigDecimal("365.2425") / 12

  attr_reader :period

  def initialize(balance_sheet, period:)
    @balance_sheet = balance_sheet
    @period = period
  end

  # Net worth change per month over `period`, or nil.
  def velocity
    return @velocity if defined?(@velocity)

    @velocity = monthly_pace(period)
  end

  # Velocity minus the prior period's velocity, or nil when either is unknown.
  def momentum
    return @momentum if defined?(@momentum)

    prior_velocity = monthly_pace(prior_period)
    @momentum = velocity && prior_velocity ? velocity - prior_velocity : nil
  end

  # The window of the same length ending the day before `period` starts.
  def prior_period
    @prior_period ||= Period.custom(start_date: period.start_date - period.days, end_date: period.start_date - 1)
  end

  private
    attr_reader :balance_sheet

    def monthly_pace(window)
      return nil unless history_covers?(window)

      values = balance_sheet.net_worth_series(period: window).values
      return nil if values.size < 2

      first, last = values.first, values.last
      days = (last.date - first.date).to_i
      return nil unless days.positive?

      per_day = (amount_of(last.value) - amount_of(first.value)) / days
      Money.new(per_day * DAYS_PER_MONTH, balance_sheet.currency)
    end

    def amount_of(value)
      (value.respond_to?(:amount) ? value.amount : value).to_d
    end

    def history_covers?(window)
      first_entry_on = first_entry_on_date
      first_entry_on.present? && first_entry_on <= window.start_date
    end

    # The earliest entry among the accounts the series is built from, which is
    # not the same as the family's earliest entry for a viewer who can see only
    # some of its accounts.
    def first_entry_on_date
      return @first_entry_on_date if defined?(@first_entry_on_date)

      account_ids = BalanceSheet::HistoricalAccountScope.new(balance_sheet.family, user: balance_sheet.user).account_ids
      @first_entry_on_date = Entry.where(account_id: account_ids).minimum(:date)
    end
end

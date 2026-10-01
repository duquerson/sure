# A dated lens over a family's spending (#130, 11.2): "what did the Bali trip
# cost?". Which transactions belong to an event is derived, not stored: every
# reportable transaction whose entry date falls in the inclusive range, plus the
# ones a person pulled in by hand (`included`), minus the ones they removed
# (`excluded`). Events are lenses, not partitions, so one transaction may
# belong to several overlapping events.
#
# What counts as a reportable transaction is what the dashboard counts, so an
# event's true cost agrees with the totals shown elsewhere: no transfers or
# other budget-excluded kinds, no excluded entries, no pending rows, no
# accounts excluded from reports. The cost and the category breakdown are
# computed by the shared IncomeStatement queries over this event's set, in the
# family currency.
#
# Every reader takes an optional `user:`. A family page may be seen by members
# who cannot see every account; passing the viewer limits the event to the
# accounts they have in their finances, exactly as the Reports page does.
class Event < ApplicationRecord
  COLORS = Tag::COLORS

  belongs_to :family
  has_many :event_transactions, dependent: :destroy

  validates :name, presence: true
  validates :start_date, :end_date, presence: true
  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }
  validate :end_date_not_before_start_date

  scope :chronological, -> { order(start_date: :desc, name: :asc, id: :asc) }

  CategoryCost = Data.define(:category, :total, :weight)
  DayCost = Data.define(:date, :amount)

  def date_range
    start_date..end_date
  end

  def days
    (end_date - start_date).to_i + 1
  end

  # The transactions that belong to this event.
  def transactions(user: nil)
    base = reportable_transactions(user)

    base.where(entries: { date: date_range })
      .or(base.where(id: event_transactions.included.select(:transaction_id)))
      .where.not(id: event_transactions.excluded.select(:transaction_id))
  end

  # Whether a transaction can count towards an event at all (a transfer, an
  # excluded entry or a pending row cannot, whatever its date or override).
  def countable?(transaction, user: nil)
    reportable_transactions(user).exists?(id: transaction.id)
  end

  # Pull a transaction in by hand (it may be dated outside the range).
  def include_transaction!(transaction)
    set_override!(transaction, "included")
  end

  # Take a transaction out by hand (it may be dated inside the range).
  def exclude_transaction!(transaction)
    set_override!(transaction, "excluded")
  end

  # Drop any manual override, so the date range alone decides again.
  def reset_transaction!(transaction)
    event_transactions.where(transaction_id: transaction.id).destroy_all
  end

  # Candidates to pull in by hand: reportable transactions dated up to `within`
  # days either side of the range, which the event does not already hold. A
  # transaction that was removed by hand is not offered; it is listed as removed
  # and restored from there.
  def nearby_transactions(user: nil, within: 14)
    overridden = event_transactions.select(:transaction_id)
    base = reportable_transactions(user).where.not(id: overridden)

    base.where(entries: { date: (start_date - within)..(start_date - 1) })
      .or(base.where(entries: { date: (end_date + 1)..(end_date + within) }))
  end

  # Expenses minus refunds over the event's transactions, in family currency.
  # Negative when refunds exceed spending.
  def true_cost(user: nil)
    rows = totals_rows(user)
    expense = rows.select { |row| row.classification == "expense" }.sum { |row| row.total.to_d }
    income = rows.select { |row| row.classification == "income" }.sum { |row| row.total.to_d }

    Money.new(expense - income, family.currency)
  end

  # Net spend per category (a subcategory rolls up into its parent), largest
  # first. A category whose refunds exceed its spend is left out, so the rows
  # sum to the spend, not necessarily to #true_cost.
  def category_breakdown(user: nil)
    net = Hash.new(BigDecimal("0"))
    totals_rows(user).each do |row|
      key = row.parent_category_id || row.category_id
      amount = row.total.to_d
      net[key] += row.classification == "expense" ? amount : -amount
    end

    spend = net.select { |_, amount| amount.positive? }
    return [] if spend.empty?

    total = spend.values.sum
    categories = family.categories.where(id: spend.keys.compact).index_by(&:id)

    spend.filter_map do |key, amount|
      category = key.nil? ? Category.uncategorized : categories[key]
      next if category.nil?

      CategoryCost.new(category: category, total: Money.new(amount, family.currency), weight: amount / total * 100)
    end.sort_by { |row| [ -row.total.amount, row.category.name ] }
  end

  # Net cost on each day, refunds netted on their own day, zero-filled. Spans
  # the event's range, widened to reach any manually included transaction
  # dated outside it. The amounts sum to #true_cost.
  def daily_series(user: nil)
    by_date = Event::DailyCosts.new(
      family,
      transactions_scope: transactions(user: user),
      date_range: date_range,
      included_account_ids: included_account_ids(user)
    ).call.index_by(&:date)

    first_day = [ start_date, *by_date.keys ].min
    last_day = [ end_date, *by_date.keys ].max

    (first_day..last_day).map do |date|
      DayCost.new(date: date, amount: Money.new(by_date[date]&.total || 0, family.currency))
    end
  end

  # The running true cost for the day-by-day chart, as a Series the shared
  # time-series chart draws. Nil when there are fewer than two days: a single
  # point has no line to draw.
  def cumulative_series(user: nil)
    days = daily_series(user: user)
    return nil if days.size < 2

    running = Money.new(0, family.currency)
    Series.from_raw_values(days.map { |day| { date: day.date, value: (running += day.amount) } })
  end

  private
    # Same rows IncomeStatement::Totals and IncomeStatement::DailyExpenseTotals
    # keep (their SQL still applies on top; the parity test in EventTest pins
    # that the two agree), expressed as a relation so the event can list them.
    def reportable_transactions(user)
      scope = family.transactions.visible.excluding_pending
        .where.not(kind: Transaction::BUDGET_EXCLUDED_KINDS)
        .where(entries: { excluded: false }, accounts: { exclude_from_reports: false })
        .where("transactions.investment_activity_label IS NULL OR transactions.investment_activity_label NOT IN (?)", Transaction::INTERNAL_MOVEMENT_LABELS)

      tax_advantaged = family.tax_advantaged_account_ids
      scope = scope.where.not(entries: { account_id: tax_advantaged }) if tax_advantaged.present?

      ids = included_account_ids(user)
      scope = scope.where(entries: { account_id: ids }) if ids
      scope
    end

    def set_override!(transaction, inclusion)
      override = event_transactions.find_or_initialize_by(transaction_id: transaction.id)
      override.update!(inclusion: inclusion)
    end

    def included_account_ids(user)
      user&.finance_accounts&.pluck(:id)
    end

    def totals_rows(user)
      IncomeStatement::Totals.new(
        family,
        transactions_scope: transactions(user: user),
        date_range: date_range,
        included_account_ids: included_account_ids(user)
      ).call
    end

    def end_date_not_before_start_date
      return if start_date.blank? || end_date.blank?

      errors.add(:end_date, :before_start) if end_date < start_date
    end
end

# A calendar-shaped grid of net spending: one row per week of the period, one
# column per weekday.
#
# Why week-of-period rather than hour-of-day: entries store a date and nothing
# else. No model persists the time a transaction happened, so an hour axis would
# have to be invented (import time is not spend time). Weekday x week keeps to
# what Sure knows. Each cell is therefore a single date.
#
# Net of refunds, on exactly the terms the budget uses: a category counts only
# if its refunds do not outweigh its spend over the whole period, and a refund
# lowers the cell of the day it landed on. That makes `total` equal
# IncomeStatement#net_category_totals' total_net_expense, which is what
# Budget#actual_spending reports. The scoping (visible, posted, reportable
# accounts, transfers and excluded entries left out) is shared with the income
# statement through Spending::DailyCategoryTotals.
#
# `user` must be the one the income statement being compared against was built
# for: it decides which accounts count.
class Spending::Heatmap
  WEEK_START = :sunday # matches the Bills calendar

  Cell = Data.define(:date, :total)
  Week = Data.define(:start_date, :end_date, :cells)

  attr_reader :period

  def initialize(family:, period:, user: nil)
    @family = family
    @period = period
    @user = user
  end

  # Rows of seven cells, Sunday first. A date outside the period is nil, so it
  # reads as "not part of this period" rather than "spent nothing".
  def weeks
    @weeks ||= begin
      first = period.start_date.beginning_of_week(WEEK_START)
      last = period.end_date.beginning_of_week(WEEK_START)

      (first..last).step(7).map do |week_start|
        dates = (week_start..week_start + 6.days)
        inside = dates.select { |date| period.date_range.cover?(date) }

        Week.new(
          start_date: inside.first,
          end_date: inside.last,
          cells: dates.map { |date| period.date_range.cover?(date) ? Cell.new(date: date, total: daily_totals.fetch(date, 0.to_d)) : nil }
        )
      end
    end
  end

  def total
    daily_totals.values.sum(0.to_d)
  end

  # Net spend for each weekday across the whole period, Sunday first.
  def weekday_totals
    weeks.flat_map(&:cells).compact.each_with_object(Array.new(7, 0.to_d)) do |cell, totals|
      totals[cell.date.wday] += cell.total
    end
  end

  # The biggest single day, for scaling the colour of a cell. Never negative:
  # the days sum to a non-negative total, so the largest of them cannot be.
  def peak
    (daily_totals.values.max || 0).to_d
  end

  private
    attr_reader :family, :user

    # { date => net total }, over net-expense categories only.
    def daily_totals
      @daily_totals ||= begin
        rows = Spending::DailyCategoryTotals.new(family, period: period, included_account_ids: included_account_ids).call
        net_expense_keys = rows.group_by(&:category_id).select { |_, group| group.sum(&:total).positive? }.keys.to_set

        rows.select { |row| net_expense_keys.include?(row.category_id) }
            .group_by(&:date)
            .transform_values { |day| day.sum(&:total) }
      end
    end

    def included_account_ids
      user&.finance_accounts&.pluck(:id)
    end
end

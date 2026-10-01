# The story of the current budget month for one viewer: pace against the
# budget, what moved against the window before it, and when the spending
# happened. The narrative page and the two insight generators both build on the
# pieces here, so they cannot tell different stories.
#
# `on` is the reference date and is always passed in: this class never reads the
# clock, so everything below -- the period, the elapsed fraction, the previous
# window -- is a function of it.
#
# The period is the month to date: from the start of the family's budget month
# to `on`. Movers and the heatmap read it as it stands, and the previous period
# is the window of equal length before it, so a half-finished month is compared
# with a like-sized stretch rather than with a whole one.
class Spending::Narrative
  attr_reader :family, :user, :on

  def initialize(family:, user:, on:)
    @family = family
    @user = user
    @on = on
  end

  def period
    @period ||= begin
      month_start, = Budget.period_for(on, family: family)
      Period.custom(start_date: month_start, end_date: on)
    end
  end

  def previous_period
    @previous_period ||= Spending::TopMovers.previous_period(period)
  end

  # The budget the viewer sees for this month: their personal one when the
  # family keeps personal budgets, the household one otherwise. Looked up, never
  # bootstrapped -- Budget.find_or_bootstrap writes, and a page view should not
  # create a budget row. nil when none exists for the month.
  def budget
    return @budget if defined?(@budget)

    month_start, month_end = Budget.period_for(on, family: family)
    owner = family.personal_budgets? ? user : nil

    @budget = family.budgets.find_by(start_date: month_start, end_date: month_end, user: owner)
    @budget.current_user = user if @budget
    @budget
  end

  def pace
    @pace ||= Spending::Pace.for(budget, on: on)
  end

  # Net spend over the previous window; what a "change" is measured against.
  def previous_spend
    income_statement.net_category_totals(period: previous_period).total_net_expense.to_d
  end

  def top_movers(limit: 5)
    Spending::TopMovers.new(income_statement: income_statement, period: period, previous_period: previous_period).movers(limit: limit)
  end

  def heatmap
    @heatmap ||= Spending::Heatmap.new(family: family, period: period, user: user)
  end

  private
    def income_statement
      @income_statement ||= family.income_statement(user: user)
    end
end

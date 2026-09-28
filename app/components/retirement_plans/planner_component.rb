# frozen_string_literal: true

# The full planner's outcome, chart and year-by-year table (#127, 8.2).
#
# Formatting only: every figure comes from the RetirementPlan::Simulation
# (and, in FIRE mode, the RetirementPlan::Solver result) the controller built
# with its one reference date.
class RetirementPlans::PlannerComponent < ViewComponent::Base
  attr_reader :plan, :simulation, :solution, :currency, :milestones

  def initialize(plan:, simulation:, solution:, currency:, milestones: [])
    @plan = plan
    @simulation = simulation
    @solution = solution
    @currency = currency
    @milestones = milestones
  end

  def fire?
    plan.mode == "fire"
  end

  # What stops the page from showing a table, if anything.
  def missing_input
    return :birth_year if plan.birth_year.nil?
    return :retirement_date if !fire? && plan.retirement_date.nil?

    nil
  end

  def rows
    simulation&.rows || []
  end

  def retired?(row)
    row.year >= simulation.retirement_year
  end

  # The milestones reached within the plan, by the year they land in (8.4a).
  def milestones_in(year)
    @milestones_by_year ||= milestones.select(&:year).group_by(&:year)
    @milestones_by_year.fetch(year, [])
  end

  def milestone_name(milestone)
    t("retirement_plans.planner.milestones.names.#{milestone.key}")
  end

  def milestone_when(milestone)
    if milestone.reached_already
      t("retirement_plans.planner.milestones.reached")
    elsif milestone.year
      t("retirement_plans.planner.milestones.in_year", year: milestone.year, age: milestone.age)
    else
      t("retirement_plans.planner.milestones.not_reached")
    end
  end

  def money(amount)
    Money.new(amount, currency).format(precision: 0)
  end

  # Two lines for the time-series chart: the portfolio in each year's money,
  # and in today's.
  def chart_series
    [
      { label: t("retirement_plans.planner.chart.nominal"),
        values: rows.map { |row| { date: Date.new(row.year, 12, 31), value: row.end_value.round(2).to_f } } },
      { label: t("retirement_plans.planner.chart.real"),
        values: rows.map { |row| { date: Date.new(row.year, 12, 31), value: row.end_value_real.round(2).to_f } } }
    ]
  end
end

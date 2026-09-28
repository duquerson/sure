# frozen_string_literal: true

# The simple FIRE tier's figures (#127, 8.1): FI number, progress towards it,
# and the projected total at retirement, with an optional compound projection
# chart. Rendered on /plan and in the /portfolio section, so both show the
# same numbers from the same RetirementPlan::Projection.
#
# Formatting only: every figure comes from the projection, which the caller
# builds with its own `as_of`.
class RetirementPlans::SummaryComponent < ViewComponent::Base
  attr_reader :projection, :currency, :unconverted_count

  def initialize(projection:, currency:, unconverted_count: 0, show_chart: false)
    @projection = projection
    @currency = currency
    @unconverted_count = unconverted_count
    @show_chart = show_chart
  end

  def show_chart?
    @show_chart && fi_number?
  end

  def fi_number?
    projection.fi_number.present?
  end

  def fi_number_money
    money(projection.fi_number)
  end

  def current_assets_money
    money(projection.current_assets)
  end

  def projected_total_money
    projection.projected_total && money(projection.projected_total)
  end

  # Whole percent for the figure; the bar reads `bar_percent`, which stops at
  # 100 once the user is independent while this keeps counting (finding 7).
  def progress_percent
    (projection.progress * 100).round
  end

  def bar_percent
    (projection.bar_progress * 100).round(1)
  end

  def savings_rate_percent
    (projection.effective_savings_rate.to_d * 100).round(1)
  end

  def savings_rate_derived?
    projection.savings_rate.nil?
  end

  # Two lines for the time-series chart: the projected portfolio, and the FI
  # number held flat, so the year the first crosses the second can be read
  # off the chart.
  def chart_series
    points = projection.yearly_series
    [
      { label: t("retirement_plans.summary.chart.projected"),
        values: points.map { |point| { date: point[:date], value: point[:value].round(2).to_f } } },
      { label: t("retirement_plans.summary.chart.fi_number"),
        values: points.map { |point| { date: point[:date], value: projection.fi_number.round(2).to_f } } }
    ]
  end

  private
    def money(amount)
      Money.new(amount, currency)
    end
end

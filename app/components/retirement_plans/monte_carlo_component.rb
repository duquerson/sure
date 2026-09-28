# frozen_string_literal: true

# The Monte Carlo result on the planner page (#127, 8.3): the chance the money
# lasts, the confident year, the stress test, the fan chart and the heatmap.
# Formatting only: the figures come from RetirementPlan#monte_carlo_result,
# computed by RetirementPlan::MonteCarloJob and cached.
class RetirementPlans::MonteCarloComponent < ViewComponent::Base
  attr_reader :plan, :result

  def initialize(plan:, result:)
    @plan = plan
    @result = result
  end

  def pending?
    result.nil?
  end

  def fire?
    plan.mode == "fire"
  end

  def percent(rate)
    helpers.number_to_percentage(rate.to_f * 100, precision: 0)
  end

  def target_met?
    result[:success_rate] >= plan.success_target.to_f
  end

  def confident_age
    result[:confident_year] && result[:confident_year] - plan.birth_year
  end

  # Five lines for the time-series chart, the 10th to the 90th percentile, in
  # today's money.
  def fan_series
    first_year = result[:as_of].year
    RetirementPlan::MonteCarlo::PERCENTILES.map do |p|
      { label: t("retirement_plans.monte_carlo.percentile", p: p),
        values: result[:percentiles].fetch(p).each_with_index.map { |value, i| { date: Date.new(first_year + i, 12, 31), value: value.round(2) } } }
    end
  end

  # Savings steps that clamp to the same rate (a plan saving 5 points or less
  # has two at 0%) ran the same inputs on the same draws, so their cells are
  # identical: each rate is shown once.
  def heatmap_rows
    columns = result[:heatmap].first.each_index.uniq { |i| savings_rate_for(result[:heatmap].first[i][:savings_step]) }
    result[:heatmap].map { |row| row.values_at(*columns) }
  end

  def return_label(step)
    helpers.number_to_percentage((result[:expected_annual_return].to_f + step) * 100, precision: 0)
  end

  def savings_label(step)
    helpers.number_to_percentage(savings_rate_for(step) * 100, precision: 0)
  end

  def savings_rate_for(step)
    (result[:savings_rate].to_f + step).clamp(0, 1)
  end

  def cell_class(rate)
    rate >= plan.success_target.to_f ? "text-success" : "text-warning"
  end
end

# Runs a retirement plan's Monte Carlo (#127, 8.3) off the request, caches the
# result under the plan's input digest, and pushes it to the planner page.
#
# The reference date comes in as an argument: the job never reads the clock,
# so the result matches the page that asked for it.
class RetirementPlan::MonteCarloJob < ApplicationJob
  queue_as :default

  def perform(retirement_plan_id, as_of_iso8601)
    plan = RetirementPlan.find_by(id: retirement_plan_id)
    return if plan.nil?

    as_of = Date.iso8601(as_of_iso8601)
    key = plan.monte_carlo_cache_key(as_of: as_of)
    result = Rails.cache.read(key)

    if result.nil?
      result = plan.monte_carlo_result(as_of: as_of)
      return if result.nil?

      Rails.cache.write(key, result, expires_in: 1.day)
    end

    Turbo::StreamsChannel.broadcast_replace_to(
      [ plan.user, :retirement_plan ],
      target: "retirement-plan-monte-carlo",
      partial: "retirement_plans/monte_carlo",
      locals: { plan: plan, result: result }
    )
  end
end

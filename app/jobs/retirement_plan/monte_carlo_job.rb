# Runs a retirement plan's Monte Carlo (#127, 8.3) off the request, caches the
# result under the plan's input digest, and pushes it to the planner page.
#
# The reference date comes in as an argument: the job never reads the clock,
# so the result matches the page that asked for it.
#
# Each run is thousands of simulated paths, so it waits behind syncs and
# user-facing work. A run that raises is recorded and dropped: the same inputs
# fail the same way on a retry. Its pending marker is left to expire, so a page
# polling for the result re-enqueues at most once per expiry.
class RetirementPlan::MonteCarloJob < ApplicationJob
  queue_as :low_priority

  discard_on StandardError do |job, error|
    retirement_plan_id, as_of = job.arguments
    DebugLogEntry.capture(
      category: "background_jobs",
      level: "error",
      message: "Retirement plan Monte Carlo run failed: #{error.message}",
      source: job.class.name,
      user: RetirementPlan.find_by(id: retirement_plan_id)&.user,
      metadata: { retirement_plan_id: retirement_plan_id, as_of: as_of, error_class: error.class.name }
    )
  end

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
    Rails.cache.delete(plan.monte_carlo_pending_key(as_of: as_of))

    Turbo::StreamsChannel.broadcast_replace_to(
      [ plan.user, :retirement_plan ],
      target: "retirement-plan-monte-carlo",
      partial: "retirement_plans/monte_carlo",
      locals: { plan: plan, result: result }
    )
  end
end

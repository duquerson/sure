# Runs a retirement plan's Monte Carlo (#127, 8.3) off the request, caches the
# result under the plan's input digest, and pushes it to the planner page.
#
# The reference date comes in as an argument: the job never reads the clock,
# so the result matches the page that asked for it.
#
# Each run is thousands of simulated paths, so it waits behind syncs and
# user-facing work. A run that raises is recorded and dropped: the same inputs
# fail the same way on a retry. Its inputs are marked failed instead, so the
# page says so rather than asking for them again.
#
# Every marker and the broadcast use the key the run started with: a plan
# saved mid-run has a new key, and its own run.
class RetirementPlan::MonteCarloJob < ApplicationJob
  queue_as :low_priority

  attr_reader :cache_key

  discard_on StandardError do |job, error|
    retirement_plan_id, as_of = job.arguments
    if job.cache_key
      Rails.cache.write(RetirementPlan.monte_carlo_marker(job.cache_key, :failed), true, expires_in: 1.day)
      Rails.cache.delete(RetirementPlan.monte_carlo_marker(job.cache_key, :pending))
    end
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
    key = @cache_key = plan.monte_carlo_cache_key(as_of: as_of)
    result = Rails.cache.read(key)

    if result.nil?
      result = plan.monte_carlo_result(as_of: as_of)
      return if result.nil?

      Rails.cache.write(key, result, expires_in: 1.day)
    end
    Rails.cache.delete(RetirementPlan.monte_carlo_marker(key, :pending))

    Turbo::StreamsChannel.broadcast_replace_to(
      [ plan.user, :retirement_plan ],
      targets: "#retirement-plan-monte-carlo[data-monte-carlo-key='#{RetirementPlan.monte_carlo_digest(key)}']",
      partial: "retirement_plans/monte_carlo",
      locals: { plan: plan, result: result, key: key }
    )
  end
end

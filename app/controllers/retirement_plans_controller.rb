class RetirementPlansController < ApplicationController
  before_action :require_preview_features!
  before_action :set_retirement_plan

  # The full planner (8.2). One reference date for every figure on the page.
  def show
    @as_of = Date.current
    @streams = @retirement_plan.persisted? ? @retirement_plan.streams.order(:kind, :start_year, :name) : RetirementPlan::Stream.none

    if @retirement_plan.mode == "fire"
      @solution = @retirement_plan.solve(as_of: @as_of)
      @simulation = @solution&.retirement_year && @retirement_plan.simulation(as_of: @as_of, retirement_year: @solution.retirement_year)
    else
      @simulation = @retirement_plan.simulation(as_of: @as_of)
    end

    load_monte_carlo
  end

  def edit
  end

  def update
    if @retirement_plan.update(retirement_plan_params)
      # Seeded after a save, never on a page view, and only the first time.
      @retirement_plan.seed_streams!(as_of: Date.current)
      redirect_back_or_to plan_path, notice: t(".success")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    # Always the signed-in user's own plan: there is no id to tamper with, and
    # `user_id` is not a permitted parameter.
    def set_retirement_plan
      @retirement_plan = RetirementPlan.for(Current.user)
    end

    # The cached Monte Carlo result, or a run enqueued for it (8.3). Only once
    # the plan is saved and can be simulated: the seed comes from its id.
    def load_monte_carlo
      @monte_carlo_available = @retirement_plan.persisted? && (@simulation.present? || @solution.present?)
      return unless @monte_carlo_available

      @monte_carlo = Rails.cache.read(@retirement_plan.monte_carlo_cache_key(as_of: @as_of))
      @retirement_plan.enqueue_monte_carlo(as_of: @as_of) if @monte_carlo.nil?
    end

    def retirement_plan_params
      params.require(:retirement_plan).permit(
        :safe_withdrawal_rate_percent, :expected_annual_return_percent, :savings_rate_percent, :retirement_date,
        :birth_year, :end_age, :inflation_rate_percent, :mode,
        :return_volatility_percent, :success_target_percent
      )
    end
end

class RetirementPlansController < ApplicationController
  before_action :require_preview_features!
  before_action :set_retirement_plan

  def edit
  end

  def update
    if @retirement_plan.update(retirement_plan_params)
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

    def retirement_plan_params
      params.require(:retirement_plan).permit(
        :safe_withdrawal_rate_percent, :expected_annual_return_percent, :savings_rate_percent, :retirement_date
      )
    end
end

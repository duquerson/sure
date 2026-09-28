# An account the user has picked to fund their retirement plan (#127, 8.2).
# With none picked, the plan uses 8.1's default: the cash, investment and
# crypto accounts the user counts in their finances.
class RetirementPlan::FundingAccount < ApplicationRecord
  self.table_name = "retirement_plan_accounts"

  belongs_to :retirement_plan
  belongs_to :account

  validates :account_id, uniqueness: { scope: :retirement_plan_id }
end

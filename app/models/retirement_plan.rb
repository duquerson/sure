# A user's settings for the simple FIRE tier (#127, 8.1).
#
# Per user, not per family: the figures a plan drives are built from the
# accounts its user can see (see #projection), so a family-level plan would
# project a different set of accounts for each member who opened it.
class RetirementPlan < ApplicationRecord
  belongs_to :user

  validates :safe_withdrawal_rate, presence: true,
                                   numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validates :expected_annual_return, presence: true,
                                     numericality: { greater_than: -1, less_than_or_equal_to: 1 }
  # Blank means "derive it from income and expenses", which is a different
  # answer from an explicit zero.
  validates :savings_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
                           allow_nil: true

  # The user's saved plan, or an unsaved one carrying the column defaults.
  # Never writes: opening a page must not create a row.
  def self.for(user)
    find_by(user: user) || new(user: user)
  end
end

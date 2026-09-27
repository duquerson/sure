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

  # The account types whose balance is money the user could live off:
  # cash, and what is invested. A property or a vehicle is wealth, but not a
  # portfolio a withdrawal rate can be applied to.
  LIQUID_AND_INVESTMENT_TYPES = %w[Depository Investment Crypto].freeze

  def projection(as_of:)
    RetirementPlan::Projection.new(
      as_of: as_of,
      annual_expenses: income_statement.median_expense(interval: "month").to_d * 12,
      annual_income: income_statement.median_income(interval: "month").to_d * 12,
      current_assets: assets_as_of(as_of).total,
      safe_withdrawal_rate: safe_withdrawal_rate,
      expected_annual_return: expected_annual_return,
      savings_rate: savings_rate,
      retirement_date: retirement_date
    )
  end

  # Accounts left out of the asset total for want of an exchange rate on the
  # reference date. The card says so rather than showing a quietly low figure.
  def unconverted_account_count(as_of:)
    assets_as_of(as_of).unconverted_count
  end

  private
    AssetTotal = Data.define(:total, :unconverted_count)

    # The same scope /portfolio uses (InvestmentStatement#investment_accounts):
    # what this user counts in their own finances. Family-wide would show a
    # member the combined balance of accounts never shared with them.
    def finance_accounts
      user.family.accounts.visible.included_in_reports.included_in_finances_for(user)
    end

    # Account scope passed explicitly, as Goal#median_monthly_expense does, so
    # the figures are this plan's user's whoever happens to be Current.
    def income_statement
      @income_statement ||= IncomeStatement.new(user.family, user: user, accounts: finance_accounts)
    end

    def assets_as_of(as_of)
      @assets_as_of ||= {}
      @assets_as_of[as_of] ||= begin
        currency = user.family.currency
        total = BigDecimal("0")
        unconverted = 0

        latest_balances(as_of).each do |row|
          total += Money.new(row.balance, row.currency).exchange_to(currency, date: as_of).amount
        rescue Money::ConversionError
          unconverted += 1
        end

        AssetTotal.new(total: total, unconverted_count: unconverted)
      end
    end

    # Each account's latest balance on or before the reference date, in the
    # account's own currency.
    def latest_balances(as_of)
      # By id rather than `merge`: the finance scope is DISTINCT, which cannot
      # sit in front of DISTINCT ON.
      Balance
        .joins(:account)
        .where(account_id: finance_accounts.where(accountable_type: LIQUID_AND_INVESTMENT_TYPES).select(:id))
        .where("balances.date <= ?", as_of)
        .where("balances.currency = accounts.currency")
        .select("DISTINCT ON (balances.account_id) balances.account_id, balances.balance, balances.currency")
        .order("balances.account_id, balances.date DESC")
    end
end

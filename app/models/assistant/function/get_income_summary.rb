# frozen_string_literal: true

class Assistant::Function::GetIncomeSummary < Assistant::Function
  include Assistant::Function::PortfolioSupport

  class << self
    def name
      "get_income_summary"
    end

    def description
      <<~INSTRUCTIONS
        Returns the dividend and interest income the user's investment and crypto
        accounts paid over a period, as the portfolio page's income section shows it:
        income by calendar month, the total, the fees charged over the same period,
        the fee ratio (fees against the average value held), and income by security.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(required: [], properties: period_properties)
  end

  def call(params = {})
    period = resolve_period(params)
    return period if period.is_a?(Hash)

    performance = investment_statement.performance(period: period)

    unless performance.any?
      return {
        period: period_summary(period),
        available: false,
        message: "No investment or crypto account history in this period for this user."
      }
    end

    income = performance.income.to_h.with_indifferent_access

    {
      period: period_summary(period),
      currency: family.currency,
      available: true,
      months: Array(income[:buckets]).map { |bucket| { month: bucket[:month], income: money(bucket[:amount]) } },
      total: money(income[:total]),
      fees: money(income[:fees]),
      average_value: money(income[:average_value]),
      fee_ratio: percent(income[:fee_ratio]),
      by_security: by_security(income[:by_security])
    }
  end

  private
    def by_security(amounts)
      amounts = amounts.to_h
      return [] if amounts.empty?

      securities = Security.where(id: amounts.keys).index_by { |security| security.id.to_s }
      amounts.map do |security_id, amount|
        security = securities[security_id.to_s]
        { security_id: security_id, ticker: security&.ticker, name: security&.name, income: money(amount) }
      end.sort_by { |row| -row[:income][:amount] }
    end
end

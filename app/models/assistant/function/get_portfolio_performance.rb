# frozen_string_literal: true

class Assistant::Function::GetPortfolioPerformance < Assistant::Function
  include Assistant::Function::PortfolioSupport

  class << self
    def name
      "get_portfolio_performance"
    end

    def description
      <<~INSTRUCTIONS
        Returns how the user's investment and crypto accounts performed over a period,
        as the portfolio page shows it: time-weighted return (the investments' own
        performance, with deposits and withdrawals removed), money-weighted return
        (what the user's money actually earned, timing included), volatility, maximum
        drawdown, and what drove the change in value (contributions, income, fees,
        market movement, revaluations and currency effects).

        A figure is null when it is withheld, never when it is zero:
        - annualised returns need at least a year of history;
        - rate_missing means a currency had no exchange rate in the period, so no
          return is reported rather than one converted at a guessed rate.
        Say why a figure is missing instead of treating it as 0.
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

    {
      period: period_summary(period),
      currency: family.currency,
      available: true,
      rate_missing: performance.rate_missing?,
      time_weighted_return: percent(performance.time_weighted_return),
      annualized_time_weighted_return: percent(performance.annualized_time_weighted_return),
      money_weighted_return: percent(performance.money_weighted_return),
      annualized_money_weighted_return: percent(performance.annualized_money_weighted_return),
      volatility: percent(performance.volatility),
      max_drawdown: percent(performance.max_drawdown),
      suppressed_days: Array(performance.suppressed_dates).size,
      drivers: drivers(performance.drivers)
    }
  end

  private
    def drivers(values)
      return nil if values.blank?

      values.to_h.transform_values { |amount| money(amount) }
    end
end

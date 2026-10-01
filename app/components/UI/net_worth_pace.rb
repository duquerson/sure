# The velocity and momentum figures beside the dashboard's net worth. Renders
# nothing until the family's history covers the whole period (see
# BalanceSheet::NetWorthVelocity), and shows momentum only when it can be read.
class UI::NetWorthPace < ApplicationComponent
  attr_reader :pace

  def initialize(balance_sheet:, period:)
    @pace = BalanceSheet::NetWorthVelocity.new(balance_sheet, period: period)
  end

  def render?
    pace.velocity.present?
  end

  def velocity_label
    signed(pace.velocity)
  end

  def momentum?
    pace.momentum.present?
  end

  def momentum_label
    signed(pace.momentum)
  end

  private
    # Sign follows what is printed: an amount that rounds to zero carries none,
    # rather than a minus in front of $0.00. U+2212 is the app's minus.
    def signed(money)
      shown = money.for_display
      return shown.format if shown.zero?

      shown.negative? ? "−#{shown.abs.format}" : "+#{shown.format}"
    end
end

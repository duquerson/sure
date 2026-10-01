# One line of a fund's holdings, as the provider reports it.
#
# `weight` is the provider's own percentage of fund assets and is stored
# unnormalised on purpose -- see the migration. `.fund_shares` is what turns a
# fund's rows into shares of the fund, and it is the ONE rule both
# `Security#look_through_weights` and `InvestmentStatement` read, so the two
# cannot answer differently for the same fund.
class Security::Constituent < ApplicationRecord
  # A list summing to at least this many percentage points is the whole fund.
  # Reported holdings rarely sum to exactly 100 -- rounding, cash, securities
  # lending -- and that drift is normalised against the actual sum, so the
  # listed names carry the fund between them. Below it the list is partial (a
  # "top holdings" feed stopping at 80, #269): it is divided by 100, so each
  # name keeps its reported share and the rest is reported as unlisted rather
  # than spread over the names that were listed. A list over 100 (overlapping
  # share classes, leverage) is also divided by its own sum, which scales the
  # names down; that case is out of scope for #269 and is left as it was.
  WHOLE_FUND_FROM = BigDecimal("99")
  PERCENT = BigDecimal("100")

  # `listed` maps each ticker to its fraction of the fund; `unlisted` is the
  # fraction no row names, zero for a whole-fund list.
  FundShares = Data.define(:listed, :unlisted)
  NO_SHARES = FundShares.new(listed: {}.freeze, unlisted: 0)

  belongs_to :security

  validates :ticker, presence: true
  validates :ticker, uniqueness: { scope: :security_id }
  # Zero is ALLOWED, and this is not a cosmetic boundary: EODHD reports a
  # rounded `Assets_%` and returns 0 for a position too small to round up to
  # 0.01. Under `greater_than: 0` that row failed validation, `create!` raised,
  # and the transaction in `store_constituents` took the ENTIRE fund's holdings
  # down with it -- so one negligible position cost the whole look-through.
  validates :weight, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  # Rows with a nil weight say nothing about the fund's split and are skipped,
  # as they always were. A list whose weights sum to zero declines to answer
  # rather than dividing by it.
  def self.fund_shares(rows)
    weighted = rows.reject { |row| row.weight.nil? }
    total = weighted.sum(&:weight)
    return NO_SHARES unless total.positive?

    divisor = total >= WHOLE_FUND_FROM ? total : PERCENT
    listed = weighted.each_with_object({}) { |row, map| map[row.ticker] = row.weight / divisor }
    FundShares.new(listed: listed, unlisted: 1 - total / divisor)
  end
end

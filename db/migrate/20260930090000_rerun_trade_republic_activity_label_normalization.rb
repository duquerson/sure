# Fork-only. Until the 2026-09-29 upstream sync, this fork's retirement plan
# migration held version 20260928090000. A database that ran it has that
# version recorded, so upstream's Trade Republic label normalisation, which
# shares the number, reads as already run there and never would. Running it
# again is safe where it did run: the translated labels it maps are gone and
# the listed labels it clears are already NULL.
class RerunTradeRepublicActivityLabelNormalization < ActiveRecord::Migration[8.1]
  def up
    # On a fresh database the migrator has already loaded it, at its own version.
    require_relative "20260928090000_normalize_trade_republic_activity_labels" unless defined?(NormalizeTradeRepublicActivityLabels)
    NormalizeTradeRepublicActivityLabels.new.up
  end

  def down
  end
end

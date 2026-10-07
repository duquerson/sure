# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261007090000_remove_cross_currency_loan_offset_links")

class RemoveCrossCurrencyLoanOffsetLinksMigrationTest < ActiveSupport::TestCase
  setup do
    @loan = accounts(:loan).loan
    family = @loan.account.family
    @stranded_offset = family.accounts.create!(name: "Stranded", balance: 1_000, currency: "USD", accountable: Depository.new)
    @matching_offset = family.accounts.create!(name: "Matching", balance: 2_000, currency: "USD", accountable: Depository.new)
    [ @stranded_offset, @matching_offset ].each(&:auto_share_with_family!)
    @loan.update!(rate_type: "variable", offset_account_ids: [ @stranded_offset.id, @matching_offset.id ])

    # Stranded the way a currency change left it before #328: no callback ran.
    @stranded_offset.update_columns(currency: "EUR")
    @stranded_link = @loan.loan_offset_accounts.find_by!(account_id: @stranded_offset.id)
    @matching_link = @loan.loan_offset_accounts.find_by!(account_id: @matching_offset.id)
  end

  test "deletes a link whose offset is in another currency from the loan" do
    run_migration

    assert_not LoanOffsetAccount.exists?(@stranded_link.id)
  end

  # accounts.currency is nullable in the database (the model requires it), and
  # `<>` never matches a NULL.
  test "deletes a link whose offset has no currency" do
    @matching_offset.update_columns(currency: nil)

    run_migration

    assert_not LoanOffsetAccount.exists?(@matching_link.id)
  end

  test "keeps a link in the loan's currency, with the same row" do
    run_migration

    assert LoanOffsetAccount.exists?(@matching_link.id)
  end

  test "can be run again" do
    run_migration

    assert_no_difference -> { LoanOffsetAccount.count } do
      run_migration
    end
  end

  private

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        RemoveCrossCurrencyLoanOffsetLinks.new.up
      end
    end
end

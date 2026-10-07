# A loan offset link was judged on currency only when it was created or
# resubmitted, so a later currency change on either side left a link whose
# offset is in another currency from the loan (#328). The loan then subtracted
# that balance at face value, and the loan form refused every save. Account now
# removes such links when a currency changes; this removes the ones stranded
# before that.
#
# The loan's projection cache lives on the Loan instance only, so deleting the
# rows directly leaves nothing stale behind.
class RemoveCrossCurrencyLoanOffsetLinks < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      DELETE FROM loan_offset_accounts AS link
      USING accounts AS offset_account, accounts AS loan_account
      WHERE offset_account.id = link.account_id
        AND loan_account.accountable_type = 'Loan'
        AND loan_account.accountable_id = link.loan_id
        AND offset_account.currency IS DISTINCT FROM loan_account.currency
    SQL
  end

  # A removed link cannot be judged valid again without its owner choosing it.
  def down
  end
end

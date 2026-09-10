class AddRateLockExpiresOnToLoans < ActiveRecord::Migration[7.2]
  def change
    # Date the fixed-rate lock (Zinsbindung) on a German mortgage-style loan
    # expires. After this date the loan typically needs to be renewed or
    # refinanced at a new rate. Only meaningful for rate_type == "fixed";
    # variable/adjustable loans don't have a lock to expire. Previously this
    # lived only as freeform text in the account notes.
    add_column :loans, :rate_lock_expires_on, :date
  end
end

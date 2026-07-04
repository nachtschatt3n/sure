class AddDescriptionAndLinkedAccountToContracts < ActiveRecord::Migration[7.2]
  def change
    # Free-text note ("Bad Camberg = municipal water", "ARAG = health insurance").
    # Can be filled by the user or by the AI enricher.
    add_column :contracts, :description, :text

    # The account this contract relates to beyond its billing account — the loan
    # it pays down, or the investment account it funds. Distinct from account_id
    # (the account the charge is billed from).
    add_reference :contracts, :linked_account, type: :uuid,
                  foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end

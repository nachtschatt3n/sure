class AddPreviousAmountToContracts < ActiveRecord::Migration[7.2]
  def change
    # The prior expected amount when a price change is detected, so the UI can
    # warn (e.g. "↑ from €19.55"). Null when no change has been observed.
    add_column :contracts, :previous_amount, :decimal, precision: 19, scale: 4
  end
end

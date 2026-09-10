class AddContractTermToLoans < ActiveRecord::Migration[7.2]
  def change
    # Free-text label for the term as literally stated on the loan contract
    # (Darlehensvertrag). Distinct from term_months, which is the actual
    # amortization/Tilgungsraten count used to compute monthly_payment and can
    # be lower than the nominal contract term when there's a drawdown /
    # Bereitstellungszeit gap before the first regular payment.
    add_column :loans, :contract_term, :string
  end
end

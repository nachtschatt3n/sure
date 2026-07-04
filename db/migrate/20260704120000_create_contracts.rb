class CreateContracts < ActiveRecord::Migration[7.2]
  def change
    create_enum :contract_frequency, %w[weekly monthly quarterly semiannual annual custom]
    create_enum :contract_status, %w[active paused cancelled]
    create_enum :contract_source, %w[manual detected]

    create_table :contracts, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :merchant, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :category, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :account, foreign_key: { on_delete: :nullify }, type: :uuid

      t.string :name, null: false
      t.enum :frequency, enum_type: :contract_frequency, null: false, default: "monthly"
      t.integer :custom_interval_months
      t.decimal :expected_amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.integer :expected_day
      t.date :next_due_date
      t.enum :status, enum_type: :contract_status, null: false, default: "active"
      t.enum :source, enum_type: :contract_source, null: false, default: "manual"
      t.string :provider
      t.integer :cancellation_notice_days
      t.text :notes

      t.timestamps
    end

    add_index :contracts, [ :family_id, :status ]
    add_index :contracts, [ :family_id, :frequency ]

    add_check_constraint :contracts, "char_length(name) <= 255", name: "chk_contracts_name_length"
    add_check_constraint :contracts, "expected_amount > 0", name: "chk_contracts_expected_amount_positive"
    add_check_constraint :contracts,
                         "expected_day IS NULL OR (expected_day >= 1 AND expected_day <= 31)",
                         name: "chk_contracts_expected_day_range"
    add_check_constraint :contracts,
                         "frequency <> 'custom' OR (custom_interval_months IS NOT NULL AND custom_interval_months > 0)",
                         name: "chk_contracts_custom_interval_present"
  end
end

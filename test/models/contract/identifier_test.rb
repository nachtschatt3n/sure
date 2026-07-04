require "test_helper"

class Contract::IdentifierTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    # Start from a clean slate so fixture contracts don't mask detection.
    @family.contracts.destroy_all
    @family.recurring_transactions.destroy_all
  end

  test "seeds a monthly contract from an active recurring transaction" do
    @family.recurring_transactions.create!(
      merchant: merchants(:netflix),
      account: @account,
      amount: 15.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 5.days.ago.to_date,
      next_expected_date: 25.days.from_now.to_date,
      status: "active"
    )

    assert_difference "@family.contracts.count", 1 do
      Contract::Identifier.new(@family).identify
    end

    contract = @family.contracts.sole
    assert_equal "monthly", contract.frequency
    assert_equal BigDecimal("15.99"), contract.expected_amount
    assert_equal merchants(:netflix).id, contract.merchant_id
    assert contract.source_detected?
  end

  test "detects an annual cadence from the gap between yearly charges" do
    [ 400.days.ago, 35.days.ago ].each do |date|
      create_transaction(account: @account, name: "Car insurance", amount: 480, currency: "USD", date: date.to_date)
    end

    Contract::Identifier.new(@family).identify

    contract = @family.contracts.find_by(name: "Car insurance")
    assert_not_nil contract
    assert_equal "annual", contract.frequency
    assert_equal BigDecimal("480"), contract.expected_amount
  end

  test "detects a quarterly cadence and buckets it separately from monthly" do
    [ 200.days.ago, 109.days.ago, 18.days.ago ].each do |date|
      create_transaction(account: @account, name: "Water bill", amount: 75, currency: "USD", date: date.to_date)
    end

    Contract::Identifier.new(@family).identify

    contract = @family.contracts.find_by(name: "Water bill")
    assert_equal "quarterly", contract.frequency
  end

  test "ignores income (inflow) and transfers" do
    # Inflow is negative in Sure — a recurring salary must not become a contract.
    [ 200.days.ago, 100.days.ago, 1.day.ago ].each do |date|
      create_transaction(account: @account, name: "Payroll", amount: -3000, currency: "USD", date: date.to_date)
    end

    assert_no_difference "@family.contracts.count" do
      Contract::Identifier.new(@family).identify
    end
  end

  test "is idempotent and never clobbers an existing contract" do
    @family.recurring_transactions.create!(
      name: "Spotify",
      account: @account,
      amount: 9.99,
      currency: "USD",
      expected_day_of_month: 12,
      last_occurrence_date: 2.days.ago.to_date,
      next_expected_date: 28.days.from_now.to_date,
      status: "active"
    )

    Contract::Identifier.new(@family).identify
    contract = @family.contracts.find_by(name: "Spotify")
    contract.update!(expected_amount: 12.99, source: "manual")

    assert_no_difference "@family.contracts.count" do
      Contract::Identifier.new(@family).identify
    end
    assert_equal BigDecimal("12.99"), contract.reload.expected_amount
  end
end

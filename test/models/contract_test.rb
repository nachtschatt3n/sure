require "test_helper"

class ContractTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @contract = contracts(:netflix_monthly)
  end

  test "fixtures are valid" do
    assert contracts(:netflix_monthly).valid?
    assert contracts(:gym_quarterly).valid?
    assert contracts(:domain_annual).valid?
  end

  test "monthly_normalized_amount normalizes each cadence to a per-month figure" do
    assert_equal BigDecimal("15.99"), contracts(:netflix_monthly).monthly_normalized_amount
    assert_equal BigDecimal("30"), contracts(:gym_quarterly).monthly_normalized_amount
    assert_equal BigDecimal("10"), contracts(:domain_annual).monthly_normalized_amount

    weekly = @family.contracts.new(name: "Coffee", frequency: :weekly, expected_amount: 10, currency: "USD")
    assert_equal BigDecimal("43.33"), weekly.monthly_normalized_amount

    semiannual = @family.contracts.new(name: "Insurance", frequency: :semiannual, expected_amount: 60, currency: "USD")
    assert_equal BigDecimal("10"), semiannual.monthly_normalized_amount

    custom = @family.contracts.new(name: "Odd", frequency: :custom, custom_interval_months: 4, expected_amount: 40, currency: "USD")
    assert_equal BigDecimal("10"), custom.monthly_normalized_amount
  end

  test "monthly_normalized_amount_money carries the contract currency" do
    money = contracts(:gym_quarterly).monthly_normalized_amount_money
    assert_equal BigDecimal("30"), money.amount
    assert_equal "USD", money.currency.iso_code
  end

  test "overdue? and days_overdue reflect a past next_due_date on active contracts" do
    overdue = contracts(:domain_annual)
    assert overdue.overdue?
    assert_equal 3, overdue.days_overdue

    upcoming = contracts(:netflix_monthly)
    assert_not upcoming.overdue?
    assert_equal 0, upcoming.days_overdue
  end

  test "paused or cancelled contracts are never overdue" do
    @contract.update!(next_due_date: 5.days.ago.to_date, status: :paused)
    assert_not @contract.overdue?
  end

  test "next_due returns the next_due_date" do
    assert_equal @contract.next_due_date, @contract.next_due
  end

  test "price change predicates reflect previous_amount" do
    assert_not @contract.price_changed?
    assert_not @contract.price_increased?

    @contract.update!(previous_amount: 12.99, expected_amount: 15.99)
    assert @contract.price_changed?
    assert @contract.price_increased?

    @contract.update!(previous_amount: 19.99)
    assert @contract.price_changed?
    assert_not @contract.price_increased?
  end

  test "requires a positive expected amount, a name, and a currency" do
    assert_not @family.contracts.new(frequency: :monthly, expected_amount: 10, currency: "USD").valid?
    assert_not @family.contracts.new(name: "X", frequency: :monthly, expected_amount: 0, currency: "USD").valid?
    assert_not @family.contracts.new(name: "X", frequency: :monthly, expected_amount: 10, currency: nil).valid?
  end

  test "expected_day must fall within 1..31" do
    assert_not @family.contracts.new(name: "X", frequency: :monthly, expected_amount: 10, currency: "USD", expected_day: 32).valid?
    assert @family.contracts.new(name: "X", frequency: :monthly, expected_amount: 10, currency: "USD", expected_day: 28).valid?
  end

  test "custom frequency requires a positive custom_interval_months" do
    without = @family.contracts.new(name: "X", frequency: :custom, expected_amount: 10, currency: "USD")
    assert_not without.valid?
    assert_includes without.errors[:custom_interval_months], I18n.t("activerecord.errors.models.contract.attributes.custom_interval_months.required_for_custom")

    with = @family.contracts.new(name: "X", frequency: :custom, custom_interval_months: 2, expected_amount: 10, currency: "USD")
    assert with.valid?
  end

  test "recent_actuals matches merchant, currency and amount band" do
    match = create_transaction(
      account: accounts(:depository),
      name: "Netflix charge",
      merchant: merchants(:netflix),
      amount: 16.50,
      currency: "USD",
      date: 10.days.ago.to_date
    )
    # Outside the ±15% band around 15.99 (min ~13.59, max ~18.39)
    create_transaction(
      account: accounts(:depository),
      name: "Netflix charge",
      merchant: merchants(:netflix),
      amount: 99.00,
      currency: "USD",
      date: 5.days.ago.to_date
    )

    ids = contracts(:netflix_monthly).recent_actuals.map(&:id)
    assert_includes ids, match.id
    assert_equal 1, ids.size
  end

  test "recent_actuals falls back to entry name when no merchant is set" do
    match = create_transaction(
      account: accounts(:depository),
      name: "Gym membership",
      amount: 90,
      currency: "USD",
      date: 1.week.ago.to_date
    )
    ids = contracts(:gym_quarterly).recent_actuals.map(&:id)
    assert_includes ids, match.id
  end
end

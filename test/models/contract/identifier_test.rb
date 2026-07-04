require "test_helper"

class Contract::IdentifierTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    # Start from a clean slate so fixture contracts don't mask detection.
    @family.contracts.destroy_all
  end

  # Post `count` same-amount charges spaced `gap` days apart, most recent
  # `last_days_ago` days ago, so the series reads as a real recurring cadence.
  def post_series(name:, amount:, count:, gap:, last_days_ago: 3, merchant: nil, account: @account)
    count.times do |i|
      create_transaction(
        account: account,
        name: name,
        merchant: merchant,
        amount: amount,
        currency: "USD",
        date: (Date.current - last_days_ago - (i * gap)).to_date
      )
    end
  end

  test "detects a monthly contract from repeated same-amount charges" do
    post_series(name: "Spotify", amount: 9.99, count: 6, gap: 30)

    Contract::Identifier.new(@family).identify

    contract = @family.contracts.find_by(name: "Spotify")
    assert_equal "monthly", contract.frequency
    assert_equal BigDecimal("9.99"), contract.expected_amount
    assert contract.source_detected?
  end

  test "detects an annual cadence from two yearly charges of a non-trivial amount" do
    post_series(name: "Car insurance", amount: 480, count: 2, gap: 365, last_days_ago: 35)

    Contract::Identifier.new(@family).identify

    contract = @family.contracts.find_by(name: "Car insurance")
    assert_equal "annual", contract.frequency
    assert_equal BigDecimal("480"), contract.expected_amount
  end

  test "detects a quarterly cadence and buckets it separately from monthly" do
    post_series(name: "Water bill", amount: 75, count: 3, gap: 91)

    Contract::Identifier.new(@family).identify

    assert_equal "quarterly", @family.contracts.find_by(name: "Water bill").frequency
  end

  test "collapses the same charge seen under a merchant and a raw bank name" do
    post_series(name: "NETFLIX.COM", amount: 15.99, count: 5, gap: 30, merchant: merchants(:netflix))
    post_series(name: "PAYPAL *NETFLIX", amount: 15.99, count: 5, gap: 30, last_days_ago: 12)

    assert_difference "@family.contracts.count", 1 do
      Contract::Identifier.new(@family).identify
    end

    contract = @family.contracts.find_by(expected_amount: 15.99)
    assert_equal merchants(:netflix).id, contract.merchant_id, "keeps the merchant-linked candidate"
  end

  test "ignores income (inflow) and transfers" do
    # Inflow is negative in Sure — a recurring salary must not become a contract.
    post_series(name: "Payroll", amount: -3000, count: 6, gap: 30)

    assert_no_difference "@family.contracts.count" do
      Contract::Identifier.new(@family).identify
    end
  end

  test "ignores incidental micro-purchases" do
    # Two look-alike bakery visits ~6 months apart: below the min amount, and a
    # sparse cadence with no merchant and a trivial amount.
    post_series(name: "Bakery", amount: 2.50, count: 2, gap: 182, last_days_ago: 20)

    assert_no_difference "@family.contracts.count" do
      Contract::Identifier.new(@family).identify
    end
  end

  test "ignores an irregular sub-monthly series (parking, not a subscription)" do
    # Five charges but wildly inconsistent gaps — not a real weekly cadence.
    [ 3, 40, 55, 120, 180 ].each do |days_ago|
      create_transaction(account: @account, name: "Q Park", amount: 5.50, currency: "USD", date: days_ago.days.ago.to_date)
    end

    assert_no_difference "@family.contracts.count" do
      Contract::Identifier.new(@family).identify
    end
  end

  test "requires enough occurrences for the cadence" do
    # Only 3 monthly charges — below the monthly minimum of 4.
    post_series(name: "Maybe monthly", amount: 12, count: 3, gap: 30)

    assert_no_difference "@family.contracts.count" do
      Contract::Identifier.new(@family).identify
    end
  end

  test "ignores a stale series whose last charge is long past" do
    # Six monthly charges, but the most recent was ~7 months ago (cancelled).
    post_series(name: "Old gym", amount: 29.99, count: 6, gap: 30, last_days_ago: 210)

    assert_no_difference "@family.contracts.count" do
      Contract::Identifier.new(@family).identify
    end
  end

  test "is idempotent and never clobbers an existing contract" do
    post_series(name: "Spotify", amount: 9.99, count: 6, gap: 30)

    Contract::Identifier.new(@family).identify
    contract = @family.contracts.find_by(name: "Spotify")
    contract.update!(expected_amount: 12.99, source: "manual")

    assert_no_difference "@family.contracts.count" do
      Contract::Identifier.new(@family).identify
    end
    assert_equal BigDecimal("12.99"), contract.reload.expected_amount
  end
end

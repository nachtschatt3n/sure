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
    assert_not contract.price_changed?
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

  test "merges a vendor split across merchant-tagged and raw-name charges" do
    # The same monthly charge, alternately tagged with a merchant and left as a
    # raw bank name — must collapse to one contract, not split below threshold.
    6.times do |i|
      create_transaction(
        account: @account, name: "Netflix", merchant: (i.even? ? merchants(:netflix) : nil),
        amount: 15.99, currency: "USD", date: (Date.current - 3 - (i * 30)).to_date
      )
    end

    assert_difference "@family.contracts.count", 1 do
      Contract::Identifier.new(@family).identify
    end
    contract = @family.contracts.sole
    assert_equal "monthly", contract.frequency
    assert_equal merchants(:netflix).id, contract.merchant_id
  end

  test "detects a sequential price increase and records the previous amount" do
    # Five months at 9.99, then three at 12.99 — one contract that got pricier.
    8.times do |i|
      create_transaction(
        account: @account, name: "Spotify",
        amount: (i < 5 ? 9.99 : 12.99), currency: "USD",
        date: (Date.current - 3 - ((7 - i) * 30)).to_date
      )
    end

    Contract::Identifier.new(@family).identify

    contract = @family.contracts.find_by(name: "Spotify")
    assert_equal BigDecimal("12.99"), contract.expected_amount
    assert_equal BigDecimal("9.99"), contract.previous_amount
    assert contract.price_increased?
  end

  test "keeps concurrent same-vendor contracts at different amounts separate" do
    # Two subscriptions from one vendor, billed monthly ~15 days apart — must
    # stay two contracts and NOT be read as a price change.
    6.times do |i|
      create_transaction(account: @account, name: "Apple", amount: 34.95, currency: "USD", date: (Date.current - 3 - (i * 30)).to_date)
      create_transaction(account: @account, name: "Apple", amount: 22.49, currency: "USD", date: (Date.current - 18 - (i * 30)).to_date)
    end

    Contract::Identifier.new(@family).identify

    apples = @family.contracts.where(name: "Apple")
    assert_equal 2, apples.count
    assert_equal [ BigDecimal("22.49"), BigDecimal("34.95") ], apples.pluck(:expected_amount).sort
    assert apples.none?(&:price_changed?)
  end

  test "ignores income (inflow) and transfers" do
    # Inflow is negative in Sure — a recurring salary must not become a contract.
    post_series(name: "Payroll", amount: -3000, count: 6, gap: 30)

    assert_no_difference "@family.contracts.count" do
      Contract::Identifier.new(@family).identify
    end
  end

  test "ignores incidental micro-purchases" do
    post_series(name: "Bakery", amount: 2.50, count: 2, gap: 182, last_days_ago: 20)

    assert_no_difference "@family.contracts.count" do
      Contract::Identifier.new(@family).identify
    end
  end

  test "ignores an irregular sub-monthly series (parking, not a subscription)" do
    [ 3, 40, 55, 120, 180 ].each do |days_ago|
      create_transaction(account: @account, name: "Q Park", amount: 5.50, currency: "USD", date: days_ago.days.ago.to_date)
    end

    assert_no_difference "@family.contracts.count" do
      Contract::Identifier.new(@family).identify
    end
  end

  test "requires enough occurrences for the cadence" do
    post_series(name: "Maybe monthly", amount: 12, count: 3, gap: 30)

    assert_no_difference "@family.contracts.count" do
      Contract::Identifier.new(@family).identify
    end
  end

  test "ignores a stale series whose last charge is long past" do
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

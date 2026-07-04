require "test_helper"

class IdentifyContractsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "seeds detected contracts for the family" do
    @family.contracts.destroy_all
    @family.recurring_transactions.destroy_all
    @family.recurring_transactions.create!(
      merchant: merchants(:netflix),
      account: accounts(:depository),
      amount: 15.99,
      currency: "USD",
      expected_day_of_month: 5,
      last_occurrence_date: 5.days.ago.to_date,
      next_expected_date: 25.days.from_now.to_date,
      status: "active"
    )

    assert_difference "@family.contracts.count", 1 do
      IdentifyContractsJob.perform_now(@family.id)
    end
  end

  test "no-ops for an unknown family" do
    assert_nothing_raised { IdentifyContractsJob.perform_now("00000000-0000-0000-0000-000000000000") }
  end
end

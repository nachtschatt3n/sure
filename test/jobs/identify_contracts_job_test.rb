require "test_helper"

class IdentifyContractsJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
  end

  test "seeds detected contracts for the family" do
    @family.contracts.destroy_all
    6.times do |i|
      create_transaction(
        account: accounts(:depository),
        name: "Spotify",
        amount: 9.99,
        currency: "USD",
        date: (Date.current - 3 - (i * 30)).to_date
      )
    end

    assert_difference "@family.contracts.count", 1 do
      IdentifyContractsJob.perform_now(@family.id)
    end
  end

  test "no-ops for an unknown family" do
    assert_nothing_raised { IdentifyContractsJob.perform_now("00000000-0000-0000-0000-000000000000") }
  end
end

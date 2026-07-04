require "test_helper"

class Contracts::OverviewComponentTest < ViewComponent::TestCase
  test "renders the monthly total, one section per cadence, and each cluster total" do
    overview = families(:dylan_family).contracts_overview
    render_inline(Contracts::OverviewComponent.new(overview: overview))

    # Ø/month rollup: 15.99 + 30 + 10 = 55.99
    assert_text "$55.99"
    # Three cadences present as section headers
    assert_text "Monthly"
    assert_text "Quarterly"
    assert_text "Yearly"
    # Quarterly cluster total
    assert_text "$90.00"
  end
end

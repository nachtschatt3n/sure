require "test_helper"

class Contracts::CardComponentTest < ViewComponent::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "renders the contract name and formatted amount" do
    render_inline(Contracts::CardComponent.new(contract: contracts(:netflix_monthly)))

    assert_text "Netflix"
    assert_text "$15.99"
  end

  test "renders an overdue pill when the next due date has passed" do
    render_inline(Contracts::CardComponent.new(contract: contracts(:domain_annual)))

    assert_text(/overdue/i)
  end

  test "shows the next due date when the contract is not overdue" do
    render_inline(Contracts::CardComponent.new(contract: contracts(:netflix_monthly)))

    assert_text(/Next/i)
  end
end

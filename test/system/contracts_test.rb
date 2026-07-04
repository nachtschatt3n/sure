require "application_system_test_case"

class ContractsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
  end

  test "preview user sees contract clusters and an overdue badge" do
    visit contracts_path

    assert_selector "h1", text: "Contracts"
    # One section header per active cadence, and the overdue contract's badge.
    assert_text "Monthly"
    assert_text "Quarterly"
    assert_text "Yearly"
    assert_text(/overdue/i)
  end
end

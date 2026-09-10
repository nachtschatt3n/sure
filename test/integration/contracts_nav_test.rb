require "test_helper"

# Guards the fork's top-level "Verträge" (Contracts) navigation entry.
#
# FORK DIVERGENCE: Contracts is a fork-only preview feature and is deliberately
# kept as a TOP-LEVEL nav item rather than folded into upstream's Plan hub.
# Upstream actively restructures `app/views/layouts/application.html.erb` (the
# 2026-08 sync replaced the explicit budgets/goals entries with `plan_nav_item`),
# so an upstream merge can silently drop this entry — leaving every contracts
# model, controller, view and test intact but the feature unreachable from the
# UI, with a fully green suite. This test is the guard against that.
class ContractsNavTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    ensure_tailwind_build
  end

  test "contracts is reachable from the nav when preview features are enabled" do
    set_preview_features(true)

    get root_path

    assert_response :success
    assert_select "a[href=?]", contracts_path
  end

  test "contracts is hidden from the nav when preview features are disabled" do
    set_preview_features(false)

    get root_path

    assert_response :success
    assert_select "a[href=?]", contracts_path, count: 0
  end

  private
    def set_preview_features(enabled)
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => enabled))
    end
end

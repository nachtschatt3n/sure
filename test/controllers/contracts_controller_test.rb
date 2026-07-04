require "test_helper"

class ContractsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    @contract = contracts(:netflix_monthly)
    ensure_tailwind_build
  end

  test "redirects users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get contracts_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "index renders the frequency clusters for a preview user" do
    get contracts_url
    assert_response :success
    assert_match(/Contracts/i, response.body)
    assert_match(@contract.name, response.body)
  end

  test "new renders the form" do
    get new_contract_url
    assert_response :success
  end

  test "create persists a contract and redirects" do
    assert_difference "@user.family.contracts.count", 1 do
      post contracts_url, params: {
        contract: {
          name: "Insurance",
          frequency: "annual",
          expected_amount: 240,
          currency: "USD"
        }
      }
    end
    assert_redirected_to contracts_path
  end

  test "create renders errors for an invalid contract" do
    assert_no_difference "@user.family.contracts.count" do
      post contracts_url, params: {
        contract: { name: "", frequency: "monthly", expected_amount: 0, currency: "USD" }
      }
    end
    assert_response :unprocessable_entity
  end

  test "update edits the contract" do
    patch contract_url(@contract), params: { contract: { expected_amount: 17.99 } }
    assert_redirected_to contracts_path
    assert_equal BigDecimal("17.99"), @contract.reload.expected_amount
  end

  test "destroy removes the contract" do
    assert_difference "@user.family.contracts.count", -1 do
      delete contract_url(@contract)
    end
    assert_redirected_to contracts_path
  end

  test "scan seeds detected contracts" do
    Contract.expects(:identify_for!).with(@user.family).returns(2)

    post scan_contracts_url

    assert_redirected_to contracts_path
    assert_match(/2/, flash[:notice])
  end
end

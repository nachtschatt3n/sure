require "test_helper"

class Family::AutoCategorizerTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Rule test", balance: 100, currency: "USD", accountable: Depository.new)
    @llm_provider = mock
    Provider::Registry.stubs(:preferred_llm_provider).returns(@llm_provider)
  end

  test "auto-categorizes transactions" do
    txn1 = create_transaction(account: @account, name: "McDonalds").transaction
    txn2 = create_transaction(account: @account, name: "Amazon purchase").transaction
    txn3 = create_transaction(account: @account, name: "Netflix subscription").transaction

    test_category = @family.categories.create!(name: "Test category")

    provider_response = provider_success_response([
      AutoCategorization.new(transaction_id: txn1.id, category_name: test_category.name),
      AutoCategorization.new(transaction_id: txn2.id, category_name: test_category.name),
      AutoCategorization.new(transaction_id: txn3.id, category_name: nil)
    ])

    @llm_provider.expects(:auto_categorize).returns(provider_response).once

    # 2 successful enrichments + 1 attempt marker for the declined txn3
    assert_difference "DataEnrichment.count", 3 do
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn1.id, txn2.id, txn3.id ]).auto_categorize
    end

    assert_equal test_category, txn1.reload.category
    assert_equal test_category, txn2.reload.category
    assert_nil txn3.reload.category

    # After auto-categorization, only successfully categorized transactions are locked
    # txn3 remains enrichable since it didn't get a category (allows retry)
    assert_equal 1, @account.transactions.reload.enrichable(:category_id).count
  end

  test "records an attempt for each transaction the model did not categorize" do
    omitted  = create_transaction(account: @account, name: "omitted").transaction
    declined = create_transaction(account: @account, name: "declined").transaction
    unmatched = create_transaction(account: @account, name: "unmatched").transaction
    @family.categories.create!(name: "Test category")

    provider_response = provider_success_response([
      # no row at all for `omitted`
      AutoCategorization.new(transaction_id: declined.id, category_name: nil),
      AutoCategorization.new(transaction_id: unmatched.id, category_name: "Not A Real Category")
    ])

    @llm_provider.expects(:auto_categorize).returns(provider_response).once

    assert_difference "DataEnrichment.count", 3 do
      Family::AutoCategorizer.new(
        @family, transaction_ids: [ omitted.id, declined.id, unmatched.id ]
      ).auto_categorize
    end

    {
      omitted => "model_omitted",
      declined => "model_declined",
      unmatched => "category_unmatched"
    }.each do |txn, reason|
      marker = DataEnrichment.find_by(enrichable: txn, attribute_name: "category_id", source: "ai")
      assert_equal reason, marker.metadata["reason"], "wrong reason recorded for #{txn.entry.name}"
      assert_nil txn.reload.category
      refute txn.locked?(:category_id)
    end
  end

  test "does not resubmit a transaction the model already declined" do
    txn = create_transaction(account: @account, name: "generic").transaction
    @family.categories.create!(name: "Test category")

    provider_response = provider_success_response([
      AutoCategorization.new(transaction_id: txn.id, category_name: nil)
    ])

    # `.once` is the assertion that matters: the second pass must not reach the provider.
    @llm_provider.expects(:auto_categorize).returns(provider_response).once

    Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize

    # Still enrichable (nothing was locked), but no longer a candidate, so a
    # second rule run costs nothing.
    assert_includes Transaction.enrichable(:category_id), txn
    assert_equal 0, Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
  end

  test "a declined transaction becomes retryable again on the short clock" do
    txn = create_transaction(account: @account, name: "generic").transaction
    @family.categories.create!(name: "Test category")

    provider_response = provider_success_response([
      AutoCategorization.new(transaction_id: txn.id, category_name: nil)
    ])
    @llm_provider.expects(:auto_categorize).returns(provider_response).twice

    Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
    assert_equal 0, Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize

    # model_declined is a model/prompt outcome, so it ages on the short TTL.
    travel_to (Enrichable::DEFAULT_RETRYABLE_ATTEMPT_TTL_DAYS + 1).days.from_now do
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
    end
  end

  test "raises when provider returns an unsuccessful response" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    @family.categories.create!(name: "Coffee")

    @llm_provider.expects(:auto_categorize)
                 .returns(provider_error_response(Provider::Error.new("Fixed prompt tokens exceed context budget")))

    error = assert_raises(Family::AutoCategorizer::Error) do
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
    end

    assert_equal "Failed to auto-categorize transactions: Fixed prompt tokens exceed context budget", error.message
  end

  private
    AutoCategorization = Provider::LlmConcept::AutoCategorization
end

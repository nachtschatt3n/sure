require "test_helper"

class Family::AutoMerchantDetectorTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Rule test", balance: 100, currency: "USD", accountable: Depository.new)
    @llm_provider = mock
    Provider::Registry.stubs(:get_provider).with(:openai).returns(@llm_provider)
    Setting.stubs(:brand_fetch_client_id).returns("123")
    Setting.stubs(:brand_fetch_logo_size).returns(40)
  end

  test "auto detects transaction merchants" do
    txn1 = create_transaction(account: @account, name: "McDonalds").transaction
    txn2 = create_transaction(account: @account, name: "Chipotle").transaction
    txn3 = create_transaction(account: @account, name: "generic").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn1.id, business_name: "McDonalds", business_url: "mcdonalds.com"),
      AutoDetectedMerchant.new(transaction_id: txn2.id, business_name: "Chipotle", business_url: "chipotle.com"),
      AutoDetectedMerchant.new(transaction_id: txn3.id, business_name: nil, business_url: nil)
    ])

    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    # Two enrichments for the detected merchants, plus one attempt marker for the
    # transaction the model declined to name.
    assert_difference "DataEnrichment.count", 3 do
      Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn1.id, txn2.id, txn3.id ]).auto_detect
    end

    assert_equal "McDonalds", txn1.reload.merchant.name
    assert_equal "Chipotle", txn2.reload.merchant.name
    assert_equal "https://cdn.brandfetch.io/mcdonalds.com/icon/fallback/lettermark/w/40/h/40?c=123", txn1.reload.merchant.logo_url
    assert_equal "https://cdn.brandfetch.io/chipotle.com/icon/fallback/lettermark/w/40/h/40?c=123", txn2.reload.merchant.logo_url
    assert_nil txn3.reload.merchant

    # After auto-detection, only successfully detected transactions are locked.
    # txn3 stays unlocked so a user or a later model can still claim it, but its
    # attempt marker keeps it out of the detector's own scope in the meantime.
    assert_equal 1, @account.transactions.reload.enrichable(:merchant_id).count
  end

  test "persists a detection that has a business name but no business url" do
    txn = create_transaction(account: @account, name: "HETZNER ONLINE GMBH").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Hetzner", business_url: nil)
    ])

    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    modified = Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect

    assert_equal 1, modified

    merchant = txn.reload.merchant
    assert_equal "Hetzner", merchant.name
    assert_nil merchant.website_url
    assert_nil merchant.logo_url

    # A successful detection locks the attribute, which is what takes it out of
    # the enrichable scope for good.
    assert txn.locked?(:merchant_id)
  end

  test "records an attempt when the model returns no business name" do
    txn = create_transaction(account: @account, name: "generic").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: nil, business_url: nil)
    ])

    # `.once` is the assertion that matters here: the second pass must not reach
    # the provider at all.
    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    assert_difference "DataEnrichment.count", 1 do
      Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect
    end

    marker = DataEnrichment.find_by(enrichable: txn, attribute_name: "merchant_id", source: "ai")
    assert_equal "no_business_name", marker.metadata["reason"]
    assert_nil txn.reload.merchant
    refute txn.locked?(:merchant_id)

    # The transaction is still enrichable, but no longer a candidate for the
    # detector, so a second rule run costs nothing.
    assert_includes Transaction.enrichable(:merchant_id), txn

    assert_equal 0, Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect
  end

  test "records an attempt when an existing provider merchant has nothing to enhance" do
    merchant = ProviderMerchant.create!(source: "plaid", name: "Corner Shop", website_url: nil)
    txn = create_transaction(account: @account, name: "CORNER SHOP", merchant: merchant).transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Corner Shop", business_url: nil)
    ])

    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    modified = nil
    assert_difference "DataEnrichment.count", 1 do
      modified = Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect
    end

    assert_equal 0, modified

    marker = DataEnrichment.find_by(enrichable: txn, attribute_name: "merchant_id", source: "ai")
    assert_equal "nothing_to_enhance", marker.metadata["reason"]

    # Nothing was enhanced, so nothing is locked -- but the batch still left a
    # trace, which is what stops the resubmission loop.
    refute txn.reload.locked?(:merchant_id)
    assert_nil merchant.reload.website_url
    refute_includes Transaction.without_recent_enrichment_attempt(:merchant_id, source: "ai"), txn
  end

  test "records an attempt when the merchant is already set" do
    merchant = ProviderMerchant.create!(source: "ai", name: "Already Known", website_url: "known.com")
    txn = create_transaction(account: @account, name: "ALREADY KNOWN", merchant: merchant).transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Already Known", business_url: "known.com")
    ])

    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    modified = nil
    assert_difference "DataEnrichment.count", 1 do
      modified = Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect
    end

    assert_equal 0, modified

    marker = DataEnrichment.find_by(enrichable: txn, attribute_name: "merchant_id", source: "ai")
    assert_equal "merchant_already_set", marker.metadata["reason"]
    assert_equal merchant, txn.reload.merchant
    refute_includes Transaction.without_recent_enrichment_attempt(:merchant_id, source: "ai"), txn
  end

  test "clearing the ai cache removes attempt markers and makes transactions retryable" do
    txn = create_transaction(account: @account, name: "generic").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: nil, business_url: nil)
    ])

    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect

    refute_includes Transaction.without_recent_enrichment_attempt(:merchant_id, source: "ai"), txn

    assert_difference "DataEnrichment.count", -1 do
      Transaction.clear_ai_cache(@family)
    end

    assert_includes Transaction.without_recent_enrichment_attempt(:merchant_id, source: "ai"), txn
  end

  private
    AutoDetectedMerchant = Provider::LlmConcept::AutoDetectedMerchant
end

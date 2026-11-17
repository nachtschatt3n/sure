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

    assert_difference "DataEnrichment.count", 2 do
      Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn1.id, txn2.id, txn3.id ]).auto_detect
    end

    assert_equal "McDonalds", txn1.reload.merchant.name
    assert_equal "Chipotle", txn2.reload.merchant.name
    assert_equal "https://cdn.brandfetch.io/mcdonalds.com/icon/fallback/lettermark/w/40/h/40?c=123", txn1.reload.merchant.logo_url
    assert_equal "https://cdn.brandfetch.io/chipotle.com/icon/fallback/lettermark/w/40/h/40?c=123", txn2.reload.merchant.logo_url
    assert_nil txn3.reload.merchant

    # After auto-detection, only successfully detected transactions are locked
    # txn3 remains enrichable since it didn't get a merchant (allows retry)
    assert_equal 1, @account.transactions.reload.enrichable(:merchant_id).count
  end

  test "an invalid AI merchant name leaves that transaction unassigned without failing the batch" do
    invalid_txn = create_transaction(account: @account, name: "Weird").transaction
    valid_txn = create_transaction(account: @account, name: "Chipotle").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: invalid_txn.id, business_name: Merchant::NO_MERCHANT_FILTER_VALUE, business_url: nil),
      AutoDetectedMerchant.new(transaction_id: valid_txn.id, business_name: "Chipotle", business_url: "chipotle.com")
    ])
    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    Family::AutoMerchantDetector.new(@family, transaction_ids: [ invalid_txn.id, valid_txn.id ]).auto_detect

    assert_nil invalid_txn.reload.merchant
    assert_equal "Chipotle", valid_txn.reload.merchant.name
  end

  # Regression: issue #3842. A family could previously get a globally-shared
  # ProviderMerchant created from LLM-extracted data derived from its own
  # transaction name/notes, which every other family could then match/reuse.
  test "creates a family-scoped merchant instead of a shared ProviderMerchant" do
    txn = create_transaction(account: @account, name: "Sushi Place").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Sushi Place", business_url: "sushiplace.example")
    ])
    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    assert_no_difference "ProviderMerchant.count" do
      Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect
    end

    merchant = txn.reload.merchant
    assert_instance_of FamilyMerchant, merchant
    assert_equal @family, merchant.family
    assert_equal "Sushi Place", merchant.name
  end

  test "creates the family merchant through FamilyMerchant.find_or_create_with_name" do
    txn = create_transaction(account: @account, name: "Sushi Place").transaction
    merchant = @family.merchants.create!(name: "Sushi Place")

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Sushi Place", business_url: "sushiplace.example")
    ])
    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once
    Family::AutoMerchantDetector.any_instance.stubs(:find_matching_user_merchant).returns(nil)
    FamilyMerchant.expects(:find_or_create_with_name)
                  .with(@family, "Sushi Place", website_url: "sushiplace.example")
                  .returns([ merchant, false ])
                  .once

    Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect

    assert_equal merchant, txn.reload.merchant
  end

  test "does not let one family's transaction text create or reuse another family's AI merchant" do
    other_family = families(:empty)
    other_account = other_family.accounts.create!(name: "Other", balance: 100, currency: "USD", accountable: Depository.new)

    txn1 = create_transaction(account: @account, name: "Shared Name Co").transaction
    txn2 = create_transaction(account: other_account, name: "Shared Name Co").transaction

    response1 = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn1.id, business_name: "Shared Name Co", business_url: "sharedname.example")
    ])
    response2 = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn2.id, business_name: "Shared Name Co", business_url: "sharedname.example")
    ])
    @llm_provider.expects(:auto_detect_merchants).returns(response1).once
    Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn1.id ]).auto_detect

    @llm_provider.expects(:auto_detect_merchants).returns(response2).once
    Family::AutoMerchantDetector.new(other_family, transaction_ids: [ txn2.id ]).auto_detect

    merchant1 = txn1.reload.merchant
    merchant2 = txn2.reload.merchant

    assert_instance_of FamilyMerchant, merchant1
    assert_instance_of FamilyMerchant, merchant2
    assert_not_equal merchant1.id, merchant2.id
    assert_equal @family, merchant1.family
    assert_equal other_family, merchant2.family
  end

  # Legacy AI-sourced ProviderMerchants were created from some family's own
  # transaction text, so another family must not pick them up by url or name.
  test "does not reuse another family's legacy AI provider merchant" do
    legacy = ProviderMerchant.create!(name: "Crafted Co", source: "ai", website_url: "crafted.example")
    txn = create_transaction(account: @account, name: "Crafted Co purchase").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Crafted Co", business_url: "crafted.example")
    ])
    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect

    merchant = txn.reload.merchant
    assert_instance_of FamilyMerchant, merchant
    assert_not_equal legacy.id, merchant.id
  end

  test "reuses an AI provider merchant this family already uses" do
    mine = ProviderMerchant.create!(name: "Mine Co", source: "ai", website_url: "mine.example")
    used = create_transaction(account: @account, name: "Earlier Mine Co").transaction
    used.update!(merchant: mine)
    txn = create_transaction(account: @account, name: "Mine Co purchase").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Mine Co", business_url: "mine.example")
    ])
    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    assert_no_difference [ "ProviderMerchant.count", "FamilyMerchant.count" ] do
      Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect
    end

    assert_equal mine.id, txn.reload.merchant.id
  end

  test "still reuses an existing shared provider merchant by website" do
    known = ProviderMerchant.create!(name: "Known Co", source: "plaid", website_url: "known.example")
    txn = create_transaction(account: @account, name: "Known Co purchase").transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Known Co", business_url: "known.example")
    ])
    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    assert_no_difference [ "ProviderMerchant.count", "FamilyMerchant.count" ] do
      Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect
    end

    assert_equal known.id, txn.reload.merchant.id
  end

  test "enhancing a provider merchant keeps its provider-supplied logo" do
    provider_logo = "https://plaid-merchant-logos.plaid.com/coffee_shop.png"
    merchant = ProviderMerchant.create!(source: "plaid", name: "Coffee Shop", logo_url: provider_logo)
    txn = create_transaction(account: @account, name: "COFFEE SHOP 123", merchant: merchant).transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Coffee Shop", business_url: "https://www.coffeeshop.com")
    ])

    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect

    merchant.reload
    assert_equal "https://www.coffeeshop.com", merchant.website_url
    assert_equal provider_logo, merchant.logo_url
  end

  test "enhancing a provider merchant without a logo builds the logo from the website's domain" do
    merchant = ProviderMerchant.create!(source: "plaid", name: "Book Store")
    txn = create_transaction(account: @account, name: "BOOK STORE 42", merchant: merchant).transaction

    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: txn.id, business_name: "Book Store", business_url: "https://www.bookstore.com")
    ])

    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    Family::AutoMerchantDetector.new(@family, transaction_ids: [ txn.id ]).auto_detect

    assert_equal "https://cdn.brandfetch.io/bookstore.com/icon/fallback/lettermark/w/40/h/40?c=123", merchant.reload.logo_url
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

  test "distinguishes why a business name is missing" do
    omitted     = create_transaction(account: @account, name: "no row comes back").transaction
    declined    = create_transaction(account: @account, name: "generic").transaction
    placeholder = create_transaction(account: @account, name: "Mol*nunc. GmbH").transaction
    rejected    = create_transaction(account: @account, name: "Some Shop").transaction

    # `omitted` is deliberately absent from the response: that is the only case
    # in which the model really said nothing.
    provider_response = provider_success_response([
      AutoDetectedMerchant.new(transaction_id: declined.id, business_name: nil, business_url: nil,
                               name_status: :declined),
      AutoDetectedMerchant.new(transaction_id: placeholder.id, business_name: nil, business_url: nil,
                               name_status: :declined_placeholder),
      AutoDetectedMerchant.new(transaction_id: rejected.id, business_name: nil, business_url: nil,
                               name_status: :rejected_implausible)
    ])

    @llm_provider.expects(:auto_detect_merchants).returns(provider_response).once

    ids = [ omitted.id, declined.id, placeholder.id, rejected.id ]
    assert_difference "DataEnrichment.count", 4 do
      Family::AutoMerchantDetector.new(@family, transaction_ids: ids).auto_detect
    end

    expected = {
      omitted => "model_omitted",
      declined => "model_declined",
      placeholder => "model_declined_placeholder",
      rejected => "name_rejected_implausible"
    }

    expected.each do |txn, reason|
      marker = DataEnrichment.find_by(enrichable: txn, attribute_name: "merchant_id", source: "ai")
      assert_equal reason, marker.metadata["reason"], "wrong reason recorded for #{txn.entry.name}"
    end
  end

  test "records an attempt when the model returns no business name" do
    txn = create_transaction(account: @account, name: "generic").transaction

    # No name_status: a provider that predates the split still records a marker
    # under the original label rather than losing the row.
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

  test "model-failure markers expire on the short clock, durable ones on the long clock" do
    declined = create_transaction(account: @account, name: "generic").transaction
    already  = create_transaction(account: @account, name: "ALREADY KNOWN").transaction

    declined.record_enrichment_attempt(:merchant_id, source: "ai", metadata: { "reason" => "model_declined" })
    already.record_enrichment_attempt(:merchant_id, source: "ai", metadata: { "reason" => "merchant_already_set" })

    assert_suppressed declined
    assert_suppressed already

    travel 8.days do
      # The prompt may well have changed in a week; ask the model again.
      assert_retryable declined
      # Whether the transaction already has a merchant has not changed.
      assert_suppressed already
    end

    travel 31.days do
      assert_retryable already
    end
  end

  test "legacy no_business_name markers age on the short clock too" do
    txn = create_transaction(account: @account, name: "generic").transaction
    txn.record_enrichment_attempt(:merchant_id, source: "ai", metadata: { "reason" => "no_business_name" })

    travel 8.days do
      assert_retryable txn
    end
  end

  test "a marker with no recorded reason keeps the long ttl" do
    txn = create_transaction(account: @account, name: "generic").transaction
    txn.record_enrichment_attempt(:merchant_id, source: "ai")

    travel 8.days do
      assert_suppressed txn
    end

    travel 31.days do
      assert_retryable txn
    end
  end

  test "a zero retryable ttl unblocks model failures without deleting any markers" do
    declined = create_transaction(account: @account, name: "generic").transaction
    already  = create_transaction(account: @account, name: "ALREADY KNOWN").transaction

    declined.record_enrichment_attempt(:merchant_id, source: "ai", metadata: { "reason" => "model_declined" })
    already.record_enrichment_attempt(:merchant_id, source: "ai", metadata: { "reason" => "merchant_already_set" })

    with_env_overrides("AI_ENRICHMENT_RETRYABLE_ATTEMPT_TTL_DAYS" => "0") do
      assert_retryable declined
      # Zero on this knob is not the global kill-switch: durable reasons keep
      # suppressing.
      assert_suppressed already
    end

    # The point of this knob over clearing the AI cache: the evidence survives.
    assert_equal 2, DataEnrichment.where(attribute_name: "merchant_id", source: "ai").count
  end

  test "a zero global ttl still disables the whole filter" do
    txn = create_transaction(account: @account, name: "generic").transaction
    txn.record_enrichment_attempt(:merchant_id, source: "ai", metadata: { "reason" => "merchant_already_set" })

    assert_suppressed txn

    with_env_overrides("AI_ENRICHMENT_ATTEMPT_TTL_DAYS" => "0") do
      assert_retryable txn
    end
  end

  private
    AutoDetectedMerchant = Provider::LlmConcept::AutoDetectedMerchant

    def detector_scope
      Transaction.without_recent_enrichment_attempt(:merchant_id, source: "ai")
    end

    def assert_suppressed(txn)
      refute_includes detector_scope, txn, "expected #{txn.id} to be suppressed"
    end

    def assert_retryable(txn)
      assert_includes detector_scope, txn, "expected #{txn.id} to be retryable"
    end
end

require "test_helper"

class Provider::Openai::AutoMerchantDetectorTest < ActiveSupport::TestCase
  setup do
    @transactions = [
      { id: "txn_1", name: "Some Amazon purchases", classification: "expense" },
      { id: "txn_2", name: "AWKWARD-POS-DEBIT-991", classification: "expense" },
      { id: "txn_3", name: "Local diner", classification: "expense" },
      { id: "txn_4", name: "Random merchant charge", classification: "expense" }
    ]
    @user_merchants = []
  end

  test "rejects a leaked chain-of-thought response instead of persisting it as a merchant name" do
    leaked_reasoning = "Let me think about this transaction carefully. Looking at the pattern, " \
      "this appears similar to transaction txn_9182 which I previously classified as a utility " \
      "payment, so I will reuse that reasoning here as well."

    fake_response = build_response(content: {
      "merchants" => [
        { "transaction_id" => "txn_2", "business_name" => leaked_reasoning, "business_url" => nil }
      ]
    }.to_json)

    client = stub_client(fake_response)

    result = build_detector(client, transactions: [ @transactions[1] ]).auto_detect_merchants

    txn2 = result.find { |r| r.transaction_id == "txn_2" }
    assert_nil txn2.business_name
    assert_nil txn2.business_url
  end

  test "rejects placeholder strings that are not the literal null the prompt asks for" do
    fake_response = build_response(content: {
      "merchants" => [
        { "transaction_id" => "txn_3", "business_name" => "n/a", "business_url" => "None" }
      ]
    }.to_json)

    client = stub_client(fake_response)

    result = build_detector(client, transactions: [ @transactions[2] ]).auto_detect_merchants

    txn3 = result.find { |r| r.transaction_id == "txn_3" }
    assert_nil txn3.business_name
    assert_nil txn3.business_url
  end

  test "accepts a normal, well-formed merchant detection" do
    fake_response = build_response(content: {
      "merchants" => [
        { "transaction_id" => "txn_1", "business_name" => "Amazon", "business_url" => "amazon.com" }
      ]
    }.to_json)

    client = stub_client(fake_response)

    result = build_detector(client, transactions: [ @transactions[0] ]).auto_detect_merchants

    txn1 = result.find { |r| r.transaction_id == "txn_1" }
    assert_equal "Amazon", txn1.business_name
    assert_equal "amazon.com", txn1.business_url
  end

  test "reports why a name is missing so a silent model can be told from a refused one" do
    leaked_reasoning = "First I consider the descriptor. Then I compare it against known " \
      "merchants. On balance this looks like a utility payment of some kind."

    fake_response = build_response(content: {
      "merchants" => [
        { "transaction_id" => "txn_1", "business_name" => "Amazon", "business_url" => "amazon.com" },
        { "transaction_id" => "txn_2", "business_name" => nil, "business_url" => nil },
        { "transaction_id" => "txn_3", "business_name" => "null", "business_url" => "null" },
        { "transaction_id" => "txn_4", "business_name" => leaked_reasoning, "business_url" => nil }
      ]
    }.to_json)

    result = build_detector(stub_client(fake_response), transactions: @transactions).auto_detect_merchants
    status = result.to_h { |r| [ r.transaction_id, r.name_status ] }

    assert_equal :accepted, status["txn_1"]
    # A JSON null and the string "null" are both refusals, but they say
    # different things about how the model reads the prompt.
    assert_equal :declined, status["txn_2"]
    assert_equal :declined_placeholder, status["txn_3"]
    # The model did answer here; we are the ones who threw it away.
    assert_equal :rejected_implausible, status["txn_4"]

    assert_nil result.find { |r| r.transaction_id == "txn_4" }.business_name
  end

  private
    def build_detector(client, transactions:)
      Provider::Openai::AutoMerchantDetector.new(
        client,
        model: "gpt-4.1-mini",
        transactions: transactions,
        user_merchants: @user_merchants,
        custom_provider: true,
        json_mode: Provider::Openai::AutoMerchantDetector::JSON_MODE_NONE
      )
    end

    def stub_client(response)
      client = mock
      client.stubs(:chat).returns(response)
      client
    end

    def build_response(content:, usage: { "total_tokens" => 42 })
      {
        "choices" => [
          { "message" => { "content" => content } }
        ],
        "usage" => usage
      }
    end
end

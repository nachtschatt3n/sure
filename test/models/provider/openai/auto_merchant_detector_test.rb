require "test_helper"

class Provider::Openai::AutoMerchantDetectorTest < ActiveSupport::TestCase
  setup do
    @client = mock
    @transactions = [
      { id: "1", name: "AMAZON.COM*1A2B3C", amount: 20, classification: "expense" }
    ]
    @user_merchants = [ { name: "Amazon" } ]
  end

  test "auto mode retries without response_format when strict JSON cannot be parsed" do
    call_params = []
    @client.expects(:chat).twice
      .with { |args| call_params << args[:parameters]; true }
      .returns(
        chat_response('{"merchants":[{"transaction_id":"1","business_name":"Ama'),
        chat_response('{"merchants":[{"transaction_id":"1","business_name":"Amazon","business_url":"amazon.com"}]}')
      )

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal 1, result.size
    assert_equal "Amazon", result.first.business_name
    assert_equal "amazon.com", result.first.business_url
    assert call_params.first[:response_format].present?, "strict attempt should send response_format"
    assert_nil call_params.second[:response_format], "retry should omit response_format"
  end

  test "auto mode retries when strict response parses but has the wrong shape" do
    @client.expects(:chat).twice
      .returns(
        chat_response('{"foo": []}'),
        chat_response('{"merchants":[{"transaction_id":"1","business_name":"Amazon","business_url":"amazon.com"}]}')
      )

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal "Amazon", result.first.business_name
  end

  test "auto mode accepts a top-level JSON array in a single call" do
    @client.expects(:chat).once
      .returns(chat_response('[{"transaction_id":"1","business_name":"Amazon","business_url":"amazon.com"}]'))

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal "Amazon", result.first.business_name
  end

  test "auto mode retries when strict response is a JSON scalar" do
    @client.expects(:chat).twice
      .returns(
        chat_response("null"),
        chat_response('{"merchants":[{"transaction_id":"1","business_name":"Amazon","business_url":"amazon.com"}]}')
      )

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal "Amazon", result.first.business_name
  end

  test "auto mode retries when every strict response item is malformed" do
    @client.expects(:chat).twice
      .returns(
        chat_response('{"merchants":[{}]}'),
        chat_response('{"merchants":[{"transaction_id":"1","business_name":"Amazon","business_url":"amazon.com"}]}')
      )

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal "Amazon", result.first.business_name
  end

  test "auto mode drops malformed items below the retry threshold instead of returning nil fields" do
    @transactions.concat([
      { id: "2", name: "SHELL OIL", amount: 50, classification: "expense" },
      { id: "3", name: "NETFLIX", amount: 15, classification: "expense" },
      { id: "4", name: "SPOTIFY", amount: 10, classification: "expense" }
    ])

    @client.expects(:chat).once
      .returns(chat_response(<<~JSON.squish))
        {"merchants":[
          {"business_name":"Shell","business_url":"shell.com"},
          {"transaction_id":"1","business_name":"Amazon"},
          {"transaction_id":"3","business_name":"Netflix","business_url":"netflix.com"},
          {"transaction_id":"4","business_name":"Spotify","business_url":"spotify.com"}
        ]}
      JSON

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal %w[1 3 4], result.map(&:transaction_id), "only the id-less item should be dropped"
    assert_equal "Amazon", result.first.business_name, "an omitted url field must not drop the merchant name"
    assert_nil result.first.business_url
  end

  test "auto mode retries when strict results lack a usable business_url" do
    @client.expects(:chat).twice
      .returns(
        chat_response('{"merchants":[{"transaction_id":"1","business_name":"Amazon"}]}'),
        chat_response('{"merchants":[{"transaction_id":"1","business_name":"Amazon","business_url":"amazon.com"}]}')
      )

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal "amazon.com", result.first.business_url
  end

  test "auto mode still falls back to none mode on HTTP 400" do
    call_params = []
    @client.expects(:chat).twice
      .with { |args| call_params << args[:parameters]; true }
      .raises(Faraday::BadRequestError.new("400"))
      .then
      .returns(chat_response('{"merchants":[{"transaction_id":"1","business_name":"Amazon","business_url":"amazon.com"}]}'))

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal "Amazon", result.first.business_name
    assert call_params.first[:response_format].present?
    assert_nil call_params.second[:response_format]
  end

  test "auto mode does not fire a second fallback when the none-mode retry returns HTTP 400" do
    @client.expects(:chat).twice
      .returns(chat_response('{"merchants":[{"transaction_id":"1"'))
      .then
      .raises(Faraday::BadRequestError.new("400"))

    assert_raises Faraday::BadRequestError do
      detector(json_mode: "auto").auto_detect_merchants
    end
  end

  test "auto mode makes a single call when strict returns merchants for all transactions" do
    @client.expects(:chat).once
      .returns(chat_response('{"merchants":[{"transaction_id":"1","business_name":"Amazon","business_url":"amazon.com"}]}'))

    result = detector(json_mode: "auto").auto_detect_merchants

    assert_equal 1, result.size
    assert_equal "Amazon", result.first.business_name
  end

  test "strict mode raises ResponseFormatError on unparseable JSON without retrying" do
    @client.expects(:chat).once
      .returns(chat_response('{"merchants":[{"transaction_id":"1"'))

    assert_raises Provider::Openai::ResponseFormatError do
      detector(json_mode: "strict").auto_detect_merchants
    end
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

    def detector(json_mode:)
      Provider::Openai::AutoMerchantDetector.new(
        @client,
        model: "test-model",
        transactions: @transactions,
        user_merchants: @user_merchants,
        custom_provider: true,
        json_mode: json_mode
      )
    end

    def chat_response(content)
      {
        "choices" => [ { "message" => { "content" => content } } ],
        "usage" => { "total_tokens" => 1 }
      }
    end

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

require "test_helper"

class Family::ContractEnricherTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @family = families(:dylan_family)
    @contract = contracts(:gym_quarterly)
    @provider = mock
    Provider::Registry.stubs(:preferred_llm_provider).returns(@provider)
  end

  test "fills a blank description from the LLM response" do
    json = [ { id: @contract.id, description: "Gym membership fee", category: nil } ].to_json
    @provider.expects(:chat_response).returns(provider_success_response(chat_with(json)))

    updated = Family::ContractEnricher.new(@family, contract_ids: [ @contract.id ]).enrich

    assert_equal 1, updated
    assert_equal "Gym membership fee", @contract.reload.description
  end

  test "assigns a category when the model names an existing one" do
    category = categories(:food_and_drink)
    json = [ { id: @contract.id, description: "Meal plan", category: category.name } ].to_json
    @provider.expects(:chat_response).returns(provider_success_response(chat_with(json)))

    Family::ContractEnricher.new(@family, contract_ids: [ @contract.id ]).enrich

    assert_equal category.id, @contract.reload.category_id
  end

  test "no-ops without an LLM provider" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    assert_equal 0, Family::ContractEnricher.new(@family).enrich
  end

  test "does not overwrite an existing description" do
    @contract.update!(description: "My own note")

    # Out of scope, so the provider is never consulted.
    assert_equal 0, Family::ContractEnricher.new(@family, contract_ids: [ @contract.id ]).enrich
    assert_equal "My own note", @contract.reload.description
  end

  test "tolerates a non-JSON model reply" do
    @provider.expects(:chat_response).returns(provider_success_response(chat_with("Sorry, I can't help.")))

    assert_equal 0, Family::ContractEnricher.new(@family, contract_ids: [ @contract.id ]).enrich
  end

  private
    def chat_with(text)
      Provider::LlmConcept::ChatResponse.new(
        id: "resp_1",
        model: "test-model",
        messages: [ Provider::LlmConcept::ChatMessage.new(id: "msg_1", output_text: text) ],
        function_requests: []
      )
    end
end

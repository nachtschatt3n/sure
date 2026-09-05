module Provider::LlmConcept
  extend ActiveSupport::Concern

  AutoCategorization = Data.define(:transaction_id, :category_name)

  def auto_categorize(transactions)
    raise NotImplementedError, "Subclasses must implement #auto_categorize"
  end

  # `name_status` explains why `business_name` is nil, which a bare nil cannot.
  # A model that answered "null" and a model that omitted the transaction
  # entirely produce the same nil, and so does a name we received but refused to
  # persist as implausible — three different problems with three different
  # fixes. Providers set it; callers record it. Optional so existing
  # constructions keep working.
  #
  # :accepted             — a usable name came back
  # :declined             — the model returned JSON null / an empty value
  # :declined_placeholder — the model returned the *string* "null"/"n/a"/…,
  #                         which is what our own prompt asks it to do
  # :rejected_implausible — a value came back and was refused (too long,
  #                         multi-line, or shaped like leaked reasoning)
  AutoDetectedMerchant = Data.define(:transaction_id, :business_name, :business_url, :name_status) do
    def initialize(transaction_id:, business_name:, business_url:, name_status: nil)
      super
    end
  end

  def auto_detect_merchants(transactions)
    raise NotImplementedError, "Subclasses must implement #auto_detect_merchants"
  end

  EnhancedMerchant = Data.define(:merchant_id, :business_url)

  def enhance_provider_merchants(merchants)
    raise NotImplementedError, "Subclasses must implement #enhance_provider_merchants"
  end

  PdfProcessingResult = Data.define(:summary, :document_type, :extracted_data)

  def supports_pdf_processing?
    false
  end

  def process_pdf(pdf_content:, family: nil)
    raise NotImplementedError, "Provider does not support PDF processing"
  end

  ChatMessage = Data.define(:id, :output_text)
  ChatStreamChunk = Data.define(:type, :data, :usage)
  ChatResponse = Data.define(:id, :model, :messages, :function_requests)
  ChatFunctionRequest = Data.define(:id, :call_id, :function_name, :function_args)

  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    tool_choice: nil,
    messages: nil,
    conversation_history: [],
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil
  )
    raise NotImplementedError, "Subclasses must implement #chat_response"
  end
end

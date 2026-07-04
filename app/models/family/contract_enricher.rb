class Family::ContractEnricher
  Error = Class.new(StandardError)

  # Max contracts per LLM request so a local model's context isn't overrun.
  BATCH_SIZE = 20

  def initialize(family, contract_ids: nil)
    @family = family
    @contract_ids = contract_ids
  end

  # Fills a short human description (and, when confident, a category) for each
  # contract that doesn't have one yet, using the family's configured LLM. Never
  # overwrites a value the user already set. Returns the number updated.
  def enrich
    return 0 unless llm_provider
    return 0 if scope.none?

    updated = 0
    scope.each_slice(BATCH_SIZE) do |batch|
      updated += enrich_batch(batch)
    end
    updated
  rescue => e
    Rails.logger.error("ContractEnricher failed for family #{family.id}: #{e.class}: #{e.message}")
    updated || 0
  end

  private
    attr_reader :family, :contract_ids

    def enrich_batch(batch)
      response = llm_provider.chat_response(
        prompt_for(batch),
        model: Provider::Openai.effective_model,
        instructions: INSTRUCTIONS
      )
      return 0 unless response.success?

      rows = parse_rows(response.data)
      return 0 if rows.blank?

      apply(batch, rows)
    end

    def apply(batch, rows)
      by_id = rows.index_by { |r| r["id"].to_s }
      updated = 0

      batch.each do |contract|
        row = by_id[contract.id.to_s]
        next if row.blank?

        attrs = {}
        if contract.description.blank? && row["description"].present?
          attrs[:description] = row["description"].to_s.strip.first(255)
        end
        if contract.category_id.nil? && (category = category_for(row["category"]))
          attrs[:category_id] = category.id
        end

        next if attrs.empty?

        contract.update!(attrs)
        updated += 1
      end

      updated
    end

    def prompt_for(batch)
      lines = batch.map do |c|
        "- id=#{c.id} | name=#{c.name} | merchant=#{c.merchant&.name} | " \
          "amount=#{c.expected_amount_money.format} | cadence=#{c.frequency}"
      end
      <<~PROMPT
        Here are recurring contracts. Available categories: #{family.categories.map(&:name).join(', ')}.

        For each, return its id, a concise description (max 12 words, what it most
        likely is — e.g. "Health insurance premium", "Municipal water & waste",
        "Auto loan repayment", "Streaming subscription"), and the best-matching
        category name from the list above (or null).

        Contracts:
        #{lines.join("\n")}
      PROMPT
    end

    INSTRUCTIONS = <<~TEXT.freeze
      You are a personal-finance assistant. Identify recurring contracts from
      their merchant name and amount. Reply with ONLY a JSON array of objects
      like [{"id": "...", "description": "...", "category": "..."}]. No prose.
    TEXT

    # Pull the first JSON array out of the model's text (local models often wrap
    # it in prose or code fences).
    def parse_rows(chat_response)
      text = Array(chat_response.messages).map(&:output_text).join("\n")
      match = text.match(/\[.*\]/m)
      return [] unless match

      parsed = JSON.parse(match[0])
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      []
    end

    def category_for(name)
      return nil if name.blank?

      family.categories.find { |c| c.name.casecmp?(name.to_s.strip) }
    end

    def scope
      relation = family.contracts.where(description: [ nil, "" ]).includes(:merchant)
      relation = relation.where(id: contract_ids) if contract_ids.present?
      relation
    end

    def llm_provider
      Provider::Registry.preferred_llm_provider
    end
end

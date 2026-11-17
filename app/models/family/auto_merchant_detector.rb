class Family::AutoMerchantDetector
  Error = Class.new(StandardError)

  def initialize(family, transaction_ids: [])
    @family = family
    @transaction_ids = transaction_ids
  end

  def auto_detect
    raise "No LLM provider for auto-detecting merchants" unless llm_provider

    if scope.none?
      Rails.logger.info("No transactions to auto-detect merchants for family #{family.id}")
      return 0
    else
      Rails.logger.info("Auto-detecting merchants for #{scope.count} transactions for family #{family.id}")
    end

    result = llm_provider.auto_detect_merchants(
      transactions: transactions_input,
      user_merchants: user_merchants_input,
      family: family
    )

    unless result.success?
      Rails.logger.error("Failed to auto-detect merchants for family #{family.id}: #{result.error.message}")
      return 0
    end

    modified_count = 0
    unchanged = {}

    scope.each do |transaction|
      auto_detection = result.data.find { |c| c.transaction_id == transaction.id }

      # A business_url is optional. It only feeds logo lookup and merchant
      # deduplication, and Merchant does not require it, so a detection that
      # names the business is still worth persisting. Requiring it here used to
      # discard otherwise-good detections from models that reliably return names
      # but rarely URLs.
      unless auto_detection&.business_name.present?
        unchanged[transaction] = missing_name_reason(auto_detection)
        next
      end

      existing_merchant = transaction.merchant

      if existing_merchant.nil?
        # Case 1: No merchant - create/find AI merchant and assign
        merchant_id = find_matching_user_merchant(auto_detection)
        merchant_id ||= find_or_create_ai_merchant(auto_detection)&.id

        if merchant_id.present?
          was_modified = transaction.enrich_attribute(:merchant_id, merchant_id, source: "ai")
          transaction.lock_attr!(:merchant_id)
          modified_count += 1 if was_modified
        else
          unchanged[transaction] = "merchant_unresolved"
        end

      elsif existing_merchant.is_a?(ProviderMerchant) && existing_merchant.source != "ai"
        # Case 2: Has provider merchant (non-AI) - enhance it with AI data
        if enhance_provider_merchant(existing_merchant, auto_detection)
          transaction.lock_attr!(:merchant_id)
          modified_count += 1
        else
          unchanged[transaction] = "nothing_to_enhance"
        end
      else
        # Case 3: AI merchant or FamilyMerchant - skip (already good or user-set)
        unchanged[transaction] = "merchant_already_set"
      end
    end

    # Every transaction the batch examined without changing gets an attempt
    # marker. Successful paths lock merchant_id and leave the enrichable scope on
    # their own; without this, the unchanged ones stay enrichable forever and are
    # resubmitted to the LLM on every rule run, at cost and with no new outcome.
    unchanged.each do |transaction, reason|
      transaction.record_enrichment_attempt(:merchant_id, source: "ai", metadata: { "reason" => reason })
    end

    modified_count
  end

  private
    attr_reader :family, :transaction_ids

    # A missing name has several distinct causes, and lumping them together is
    # what made a previous production run unreadable: 142 transactions all
    # recorded "no_business_name", which was read as "the model returns
    # nothing" when in fact the model had answered for nearly all of them.
    #
    # Splitting the reason makes the follow-up question answerable with one
    # GROUP BY over data_enrichments.metadata->>'reason' instead of a manual
    # audit:
    #
    #   model_omitted             the batch response had no row for this
    #                             transaction at all — the only case where the
    #                             model really was silent
    #   model_declined            the model answered with a null
    #   model_declined_placeholder the model answered with the string "null",
    #                             as our own prompt instructs it to
    #   name_rejected_implausible we received a name and refused it (too long,
    #                             multi-line, or leaked reasoning text)
    def missing_name_reason(auto_detection)
      return "model_omitted" if auto_detection.nil?

      case auto_detection.name_status
      when :declined             then "model_declined"
      when :declined_placeholder then "model_declined_placeholder"
      when :rejected_implausible then "name_rejected_implausible"
      else
        # A provider that predates name_status, or one that reported :accepted
        # while handing back a blank name. Neither should happen; keep the old
        # label so the row is still counted rather than lost.
        "no_business_name"
      end
    end

    # Honors Setting.llm_provider (issue #2113) — Provider::Anthropic implements
    # auto_detect_merchants (PR #1984), so batch merchant detection routes to the
    # configured provider, with fallback handled by
    # Provider::Registry.preferred_llm_provider.
    def llm_provider
      Provider::Registry.preferred_llm_provider
    end

    def user_merchants_input
      family.merchants.map do |merchant|
        {
          id: merchant.id,
          name: merchant.name
        }
      end
    end

    def transactions_input
      scope.map do |transaction|
        {
          id: transaction.id,
          amount: transaction.entry.amount.abs,
          classification: transaction.entry.classification,
          description: [ transaction.entry.name, transaction.entry.notes ].compact.reject(&:empty?).join(" "),
          merchant: transaction.merchant&.name
        }
      end
    end

    def scope
      family.transactions.where(id: transaction_ids)
                         .enrichable(:merchant_id)
                         .without_recent_enrichment_attempt(:merchant_id, source: "ai")
                         .includes(:merchant, :entry)
    end

    def find_matching_user_merchant(auto_detection)
      user_merchants_input.find { |m| m[:name] == auto_detection.business_name }&.dig(:id)
    end

    def find_or_create_ai_merchant(auto_detection)
      # Strategy 1: Find an existing merchant by website_url (most reliable for
      # deduplication). Provider-sourced merchants (Plaid etc.) are vetted
      # shared data and stay reusable across families. AI-sourced ones were
      # created from some family's own transaction text (before #3842), so
      # they're only reused when already assigned to this family — otherwise
      # another family's crafted name/logo would surface here.
      if auto_detection.business_url.present?
        existing = reusable_provider_merchants.find_by(website_url: auto_detection.business_url)
        return existing if existing
      end

      # Strategy 2: Find an AI-sourced merchant by exact name match, limited
      # to the ones this family already uses (see Strategy 1).
      existing = family_ai_provider_merchants.find_by(name: auto_detection.business_name)
      return existing if existing

      # Strategy 3: no shared merchant to reuse. Create a merchant scoped to
      # this family rather than a globally-shared ProviderMerchant, so a
      # family can't use LLM-extracted data derived from its own transaction
      # description/notes to create a record visible to every other family
      # (issue #3842).
      merchant, _created = FamilyMerchant.find_or_create_with_name(
        family,
        auto_detection.business_name,
        website_url: auto_detection.business_url
      )
      merchant
    rescue ActiveRecord::RecordInvalid => e
      # A name the model rejects (e.g. the reserved Merchant::NO_MERCHANT_FILTER_VALUE)
      # leaves this transaction without a merchant, as before, instead of
      # failing the whole detection batch. The name itself isn't logged since
      # it's derived from the family's transaction text.
      Rails.logger.warn("Skipping invalid AI-detected merchant for family #{family.id}: #{e.record.errors.attribute_names.join(', ')}")
      nil
    end

    def family_ai_provider_merchants
      ProviderMerchant.where(source: "ai", id: family.transactions.select(:merchant_id))
    end

    def reusable_provider_merchants
      ProviderMerchant.where.not(source: "ai").or(family_ai_provider_merchants)
    end

    def enhance_provider_merchant(merchant, auto_detection)
      updates = {}

      # Add website_url if missing. ProviderMerchant fills a blank logo from it
      # and keeps a provider-supplied one (issue #2925).
      if merchant.website_url.blank? && auto_detection.business_url.present?
        updates[:website_url] = auto_detection.business_url
      end

      return false if updates.empty?

      merchant.update!(updates)
      true
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Failed to enhance merchant #{merchant.id}: #{e.message}")
      false
    end
end

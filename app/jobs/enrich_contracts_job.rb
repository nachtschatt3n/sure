class EnrichContractsJob < ApplicationJob
  queue_as :ai_low_priority

  def perform(family_id, contract_ids: nil)
    family = Family.find_by(id: family_id)
    return unless family

    Family::ContractEnricher.new(family, contract_ids: contract_ids).enrich
  end
end

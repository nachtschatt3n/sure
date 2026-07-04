class Contracts::CardComponent < ApplicationComponent
  def initialize(contract:)
    @contract = contract
  end

  attr_reader :contract

  def amount_label
    contract.expected_amount_money.format
  end

  def description
    contract.description.presence
  end

  def linked_account_label
    contract.linked_account&.name
  end

  def next_due_label
    return nil if contract.next_due_date.blank?

    I18n.l(contract.next_due_date, format: :long)
  end

  def overdue?
    contract.overdue?
  end

  def overdue_label
    I18n.t("contracts.card.overdue", count: contract.days_overdue)
  end

  def price_increased?
    contract.price_increased?
  end

  def price_increase_label
    I18n.t("contracts.card.price_increased", amount: contract.previous_amount_money.format)
  end
end

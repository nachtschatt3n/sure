class Contract < ApplicationRecord
  include Monetizable

  belongs_to :family
  belongs_to :merchant, optional: true
  belongs_to :category, optional: true
  belongs_to :account, optional: true
  # The loan/investment/asset account this contract relates to (the debt it
  # pays down, the investment it funds), distinct from the billing account.
  belongs_to :linked_account, class_name: "Account", optional: true

  # String-backed enums (Postgres enum columns store the label directly), so the
  # hash form maps each name to its own string rather than an integer.
  enum :frequency, {
    weekly: "weekly",
    monthly: "monthly",
    quarterly: "quarterly",
    semiannual: "semiannual",
    annual: "annual",
    custom: "custom"
  }, validate: true

  enum :status, {
    active: "active",
    paused: "paused",
    cancelled: "cancelled"
  }, default: "active", validate: true

  enum :source, {
    manual: "manual",
    detected: "detected"
  }, default: "manual", validate: true, prefix: :source

  monetize :expected_amount, :previous_amount

  validates :name, presence: true, length: { maximum: 255 }
  validates :expected_amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validates :expected_day, numericality: { in: 1..31 }, allow_nil: true
  validates :custom_interval_months,
            numericality: { only_integer: true, greater_than: 0 },
            allow_nil: true
  validate :custom_interval_required_for_custom
  validate :linked_records_belong_to_family

  scope :alphabetically, -> { order(Arel.sql("LOWER(name) ASC")) }

  # Seed detected contract candidates for the family (idempotent). Returns the
  # number of contracts created.
  def self.identify_for!(family)
    Identifier.new(family).identify
  end

  # Average number of calendar months between two occurrences of the contract.
  # Weekly is expressed as a fraction of a month (52 weeks / 12 months) so the
  # normalized rollup treats a weekly charge as ~4.33 hits per month.
  MONTHS_PER = {
    "weekly" => 12.0 / 52.0,
    "monthly" => 1.0,
    "quarterly" => 3.0,
    "semiannual" => 6.0,
    "annual" => 12.0
  }.freeze

  # Months between occurrences for this contract. Custom contracts carry their
  # own interval; everything else reads the fixed MONTHS_PER map.
  def months_per_occurrence
    return custom_interval_months.to_d if custom?

    MONTHS_PER[frequency]&.to_d
  end

  # The contract's cost expressed as a per-month figure so charges on different
  # cadences can be summed into one comparable "Ø / month" spend rollup.
  def monthly_normalized_amount
    per = months_per_occurrence
    return 0.to_d if per.nil? || per.zero?

    (expected_amount.to_d / per).round(2)
  end

  def monthly_normalized_amount_money
    Money.new(monthly_normalized_amount, currency)
  end

  def next_due
    next_due_date
  end

  # True when the expected amount differs from the last-known amount (a price
  # change was detected). `price_increased?` is the one worth warning about.
  def price_changed?
    previous_amount.present? && previous_amount != expected_amount
  end

  def price_increased?
    previous_amount.present? && previous_amount < expected_amount
  end

  # A contract is overdue when its next expected charge date has passed and it
  # is still active (paused / cancelled contracts don't nag).
  def overdue?
    active? && next_due_date.present? && next_due_date < Date.current
  end

  def days_overdue
    return 0 unless overdue?

    (Date.current - next_due_date).to_i
  end

  # Real transactions that plausibly settle this contract: same currency (and
  # account, when the contract is account-scoped), matched by merchant when
  # present or else by entry name, within a ±15% amount band around the
  # expected amount. Reuses the merchant-or-name grouping shape from
  # RecurringTransaction::Identifier so detection and reconciliation agree.
  def recent_actuals(months: 12)
    band = expected_amount.to_d * BigDecimal("0.15")
    low = expected_amount.to_d - band
    high = expected_amount.to_d + band

    scope = family.entries
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(entryable_type: "Transaction")
      .where("entries.date >= ?", months.months.ago.to_date)
      .where(currency: currency)
      .where("ABS(entries.amount) BETWEEN ? AND ?", low, high)
    scope = scope.where(account_id: account_id) if account_id.present?

    if merchant_id.present?
      scope = scope.where("transactions.merchant_id = ?", merchant_id)
    else
      scope = scope.where(entries: { name: name })
    end

    scope.order(date: :desc)
  end

  private
    def custom_interval_required_for_custom
      return unless custom?
      return if custom_interval_months.to_i.positive?

      errors.add(:custom_interval_months, :required_for_custom)
    end

    # Guard against cross-family assignment via mass-assigned foreign keys: the
    # linked account/category/merchant must belong to this contract's family.
    # Provider (global) merchants have no family and are shared, so they're
    # allowed; only a FamilyMerchant is family-scoped.
    def linked_records_belong_to_family
      errors.add(:account, :invalid) if account && account.family_id != family_id
      errors.add(:linked_account, :invalid) if linked_account && linked_account.family_id != family_id
      errors.add(:category, :invalid) if category && category.family_id != family_id
      errors.add(:merchant, :invalid) if merchant.is_a?(FamilyMerchant) && merchant.family_id != family_id
    end
end

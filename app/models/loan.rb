class Loan < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "home_equity" => { short: "Home Equity", long: "Home Equity Loan" },
    "line_of_credit" => { short: "Line of Credit", long: "Line of Credit" },
    "business" => { short: "Business Loan", long: "Business Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze

  # Warning window for the "expiring soon" indicator on rate_lock_expires_on.
  # 24 months gives enough runway to shop/renegotiate a follow-up rate before
  # a German mortgage's Zinsbindung actually lapses (Prolongation offers
  # typically arrive well ahead of expiry, but borrowers benefit from
  # comparing rates early); a shorter window would surface the warning too
  # late to act on, a longer one would make it fire years in advance and lose
  # its signal value.
  RATE_LOCK_WARNING_WINDOW = 24.months

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true

  # Only fixed-rate loans have a rate lock that can expire — variable/adjustable
  # loans reprice continuously, so there's nothing to "lock" or renew.
  def rate_lock_expiring_soon?
    return false unless rate_type == "fixed" && rate_lock_expires_on.present?

    rate_lock_expires_on <= RATE_LOCK_WARNING_WINDOW.from_now.to_date
  end

  def monthly_payment
    return nil if term_months.nil? || interest_rate.nil? || rate_type.nil? || rate_type != "fixed"
    return Money.new(0, account.currency) if account.loan.original_balance.amount.zero? || term_months.zero?

    annual_rate = interest_rate / 100.0
    monthly_rate = annual_rate / 12.0

    if monthly_rate.zero?
      payment = account.loan.original_balance.amount / term_months
    else
      payment = (account.loan.original_balance.amount * monthly_rate * (1 + monthly_rate)**term_months) / ((1 + monthly_rate)**term_months - 1)
    end

    Money.new(payment.round, account.currency)
  end

  def original_balance
    Money.new(account.first_valuation_amount, account.currency)
  end

  class << self
    def color
      "#D444F1"
    end

    def icon
      "hand-coins"
    end

    def classification
      "liability"
    end
  end
end

class Contract
  # Suggests Contract candidates for a family and seeds them as `source:
  # "detected"` rows the user then curates. Deliberately non-destructive — never
  # touches an existing contract, so manual edits and user-authored contracts
  # always win.
  #
  # The pipeline is candidate → dedupe → persist:
  #
  #   1. Build candidates from repeated *expense* charges over the last 24
  #      months, grouped by merchant-or-name + amount + account. A group becomes
  #      a candidate only if its charges recur on a recognizable cadence — enough
  #      occurrences, consistent gaps, and a recent-enough last charge.
  #   2. Collapse duplicates: the same real charge is often picked up twice, once
  #      under a detected merchant and once under the raw bank-statement name (or
  #      a PayPal intermediary). Candidates sharing cadence + account + currency +
  #      amount are merged, preferring the merchant-linked one.
  #   3. Persist the survivors, skipping any the family already has a contract
  #      for (so re-scanning is idempotent).
  #
  # Detection is intentionally conservative: a wrong suggestion costs the user a
  # deletion, so we favor precision over recall. Income and transfers are
  # excluded (only positive-amount, non-transfer transactions), micro-purchases
  # are ignored, and sparse long-cadence patterns need a merchant or a
  # non-trivial amount to qualify.
  class Identifier
    LOOKBACK_MONTHS = 24

    # Below this, a repeated charge is treated as incidental spend (parking,
    # bakery, coffee) rather than a contract.
    MIN_AMOUNT = BigDecimal("3")

    # Long cadences only get 2-4 hits in 24 months, which is hard to tell from
    # coincidence — so require either a recognized merchant or a non-trivial
    # amount (insurance, domains, memberships) before trusting them.
    SPARSE_CADENCE_MIN_AMOUNT = BigDecimal("15")

    # nominal gap (days), the window a median gap must land in, the minimum
    # number of occurrences, and how recent the last charge must be to still be
    # considered active.
    CADENCES = [
      { name: "weekly",     gap: 7,   low: 5,   high: 10,  min_occurrences: 6, recency_days: 21 },
      { name: "monthly",    gap: 30,  low: 24,  high: 38,  min_occurrences: 4, recency_days: 50 },
      { name: "quarterly",  gap: 91,  low: 75,  high: 110, min_occurrences: 3, recency_days: 130 },
      { name: "semiannual", gap: 182, low: 150, high: 210, min_occurrences: 2, recency_days: 250 },
      { name: "annual",     gap: 365, low: 320, high: 410, min_occurrences: 2, recency_days: 430 }
    ].freeze

    attr_reader :family

    def initialize(family)
      @family = family
    end

    # Seeds detected contracts and returns the number created.
    def identify
      persist(dedupe(build_candidates))
    end

    private
      def build_candidates
        merchant_names = family.merchants.pluck(:id, :name).to_h

        grouped_expense_entries.filter_map do |(identifier, amount, currency, account_id), entries|
          next if amount < MIN_AMOUNT

          dates = entries.map(&:date).uniq.sort
          cadence = classify(dates)
          next if cadence.nil?
          next if sparse?(cadence) && amount < SPARSE_CADENCE_MIN_AMOUNT && identifier.first != :merchant

          type, value = identifier
          name = type == :merchant ? merchant_names[value] : value
          next if name.blank?

          {
            name: name,
            merchant_id: type == :merchant ? value : nil,
            account_id: account_id,
            currency: currency,
            frequency: cadence[:name],
            expected_amount: amount,
            expected_day: median(dates.map(&:day)),
            next_due_date: advance(dates.last, cadence[:name]),
            occurrences: dates.size
          }
        end
      end

      # The cadence a series of charge dates fits, or nil. A fit needs the median
      # gap to land in a cadence window, enough occurrences for that cadence,
      # consistent gaps (most within ~40% of the nominal), and a recent last
      # charge (so cancelled subscriptions age out).
      def classify(dates)
        return nil if dates.size < 2

        gaps = dates.each_cons(2).map { |a, b| (b - a).to_i }
        median_gap = median(gaps)
        cadence = CADENCES.find { |c| median_gap.between?(c[:low], c[:high]) }
        return nil if cadence.nil?
        return nil if dates.size < cadence[:min_occurrences]
        return nil if (Date.current - dates.last).to_i > cadence[:recency_days]

        tolerance = (cadence[:gap] * 0.4).round
        consistent = gaps.count { |g| (g - cadence[:gap]).abs <= tolerance }
        return nil if consistent.to_f / gaps.size < 0.6

        cadence
      end

      def sparse?(cadence)
        cadence[:min_occurrences] <= 2
      end

      # Same merchant-or-name + amount + currency + account grouping shape as
      # RecurringTransaction::Identifier so detection and reconciliation agree.
      # Restricted to expenses (inflow is negative in Sure, so positive-only
      # drops salary/benefits) and non-transfer transactions.
      def grouped_expense_entries
        family.entries
              .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
              .where(entryable_type: "Transaction")
              .where("entries.date >= ?", LOOKBACK_MONTHS.months.ago.to_date)
              .where("entries.amount > 0")
              .where.not("transactions.kind": Transaction::TRANSFER_KINDS)
              .includes(:entryable)
              .to_a
              .select { |entry| entry.entryable.is_a?(Transaction) }
              .group_by do |entry|
                transaction = entry.entryable
                identifier = transaction.merchant_id.present? ? [ :merchant, transaction.merchant_id ] : [ :name, entry.name ]
                [ identifier, entry.amount.round(2), entry.currency, entry.account_id ]
              end
      end

      # Collapse candidates that are the same charge seen under both a merchant
      # and a raw bank-name (or PayPal) group: same cadence + account + currency
      # + amount. Keep the merchant-linked one, then the one with more
      # occurrences, then the shorter (cleaner) name.
      def dedupe(candidates)
        candidates
          .group_by { |c| [ c[:frequency], c[:account_id], c[:currency], c[:expected_amount] ] }
          .values
          .map do |group|
            group.max_by { |c| [ c[:merchant_id] ? 1 : 0, c[:occurrences], -c[:name].length ] }
          end
      end

      def persist(candidates)
        candidates.count { |attrs| create_detected_contract(attrs.except(:occurrences)) }
      end

      # Create only when no contract already covers this merchant-or-name +
      # account + currency + cadence, so re-scanning is idempotent and never
      # clobbers a curated row.
      def create_detected_contract(attrs)
        scope = family.contracts.where(
          frequency: attrs[:frequency],
          account_id: attrs[:account_id],
          currency: attrs[:currency]
        )
        scope = if attrs[:merchant_id].present?
          scope.where(merchant_id: attrs[:merchant_id])
        else
          scope.where(merchant_id: nil, name: attrs[:name])
        end
        return false if scope.exists?

        family.contracts.create!(attrs.merge(source: "detected"))
        true
      end

      def advance(date, frequency)
        frequency == "weekly" ? date + 7 : date >> Contract::MONTHS_PER[frequency].to_i
      end

      def median(values)
        return nil if values.empty?

        sorted = values.sort
        mid = sorted.size / 2
        sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round
      end
  end
end

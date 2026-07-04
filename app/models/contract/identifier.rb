class Contract
  # Suggests Contract candidates for a family and seeds them as `source:
  # "detected"` rows the user then curates. Two passes, deliberately
  # non-destructive (never touches an existing contract, so manual edits and
  # user-authored contracts always win):
  #
  #   1. Monthly, from the family's existing recurring_transactions — the
  #      monthly-only detector already found these, so we mirror them.
  #   2. Weekly / quarterly / semiannual / annual, from the gap between repeated
  #      charges over the last 24 months. This is the dimension the
  #      recurring_transactions detector can't see (it clusters on a single
  #      day-of-month and needs 3 hits in 3 months, so longer cadences never
  #      register).
  class Identifier
    LOOKBACK_MONTHS = 24
    MIN_OCCURRENCES = 2

    # Median gap in days → cadence. Monthly is intentionally absent: those are
    # seeded from recurring_transactions so the two passes don't collide.
    GAP_BUCKETS = [
      [ 5..10,    "weekly" ],
      [ 75..110,  "quarterly" ],
      [ 155..210, "semiannual" ],
      [ 320..410, "annual" ]
    ].freeze

    attr_reader :family

    def initialize(family)
      @family = family
    end

    # Seeds detected contracts and returns the number created.
    def identify
      seed_from_recurring_transactions + seed_from_gap_cadence
    end

    private
      def seed_from_recurring_transactions
        created = 0

        family.recurring_transactions
              .where(status: "active", destination_account_id: nil)
              .includes(:merchant)
              .find_each do |recurring|
          amount = recurring.amount.to_d.abs
          next unless amount.positive?

          name = recurring.name.presence || recurring.merchant&.name
          next if name.blank?

          created += 1 if create_detected_contract(
            name: name,
            merchant_id: recurring.merchant_id,
            account_id: recurring.account_id,
            currency: recurring.currency,
            frequency: "monthly",
            expected_amount: amount,
            expected_day: recurring.expected_day_of_month,
            next_due_date: recurring.next_expected_date
          )
        end

        created
      end

      def seed_from_gap_cadence
        merchant_names = family.merchants.pluck(:id, :name).to_h
        created = 0

        grouped_expense_entries.each do |(identifier, amount, currency, account_id), entries|
          next if entries.size < MIN_OCCURRENCES
          next unless amount.positive? # expenses only (inflow is negative in Sure)

          dates = entries.map(&:date).sort
          frequency = frequency_for_gap(median(dates.each_cons(2).map { |a, b| (b - a).to_i }))
          next if frequency.nil?

          type, value = identifier
          name = type == :merchant ? merchant_names[value] : value
          next if name.blank?

          created += 1 if create_detected_contract(
            name: name,
            merchant_id: type == :merchant ? value : nil,
            account_id: account_id,
            currency: currency,
            frequency: frequency,
            expected_amount: amount.abs,
            expected_day: median(dates.map(&:day)),
            next_due_date: advance(dates.last, frequency)
          )
        end

        created
      end

      # Same merchant-or-name + amount + currency + account grouping shape as
      # RecurringTransaction::Identifier so detection and reconciliation agree.
      def grouped_expense_entries
        family.entries
              .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
              .where(entryable_type: "Transaction")
              .where("entries.date >= ?", LOOKBACK_MONTHS.months.ago.to_date)
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

      def frequency_for_gap(median_gap)
        return nil if median_gap.nil?

        bucket = GAP_BUCKETS.find { |range, _| range.cover?(median_gap) }
        bucket&.last
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

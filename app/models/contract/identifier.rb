class Contract
  # Suggests Contract candidates for a family and seeds them as `source:
  # "detected"` rows the user then curates. Non-destructive — never touches an
  # existing contract, so manual edits and user-authored contracts always win.
  #
  # The method is vendor-centric and precision-first (a wrong suggestion costs a
  # deletion, so we favor precision over recall):
  #
  #   1. Take repeated *expense* charges (positive, non-transfer) over 24 months.
  #      Income, salary, and internal transfers are excluded at the source.
  #   2. Identify the vendor by a canonical of the merchant name (or the raw
  #      bank-statement name when unmerchanted), so the same charge seen once
  #      with a detected merchant and once as a raw name isn't split in two.
  #   3. Group by vendor + account + exact amount into "blocks", and keep a block
  #      only if its charges recur on a recognizable cadence (enough occurrences,
  #      consistent gaps). Exact-amount blocks keep genuinely concurrent
  #      same-vendor contracts separate (e.g. three house loans, two Apple subs).
  #   4. Walk each block forward along its cadence grid to absorb a *sequential*
  #      price change (e.g. Hetzner 19.55 -> 25.68), recording the prior amount.
  #      A charge that arrives mid-cycle, or an old amount that keeps recurring,
  #      is a concurrent charge and is left alone — so price changes and parallel
  #      subscriptions are told apart.
  #   5. Drop stale (cancelled) series, dedupe, and persist the survivors that the
  #      family doesn't already have a contract for.
  #
  # Long-cadence (annual) coverage is inherently limited by gaps in transaction
  # history and is expected to be completed by manual curation.
  class Identifier
    LOOKBACK_MONTHS = 24
    MIN_AMOUNT = BigDecimal("3")

    # Long cadences get only 2-4 hits in 24 months, so a bare pair is hard to
    # tell from coincidence — require a recognized merchant or a non-trivial
    # amount, and suppress vendors that bill many different amounts (retail).
    SPARSE_MIN_AMOUNT = BigDecimal("15")
    RETAIL_DISTINCT_AMOUNTS = 4

    # nominal gap (days), the window a median gap must fall in, the minimum number
    # of occurrences, and how recent the last charge must be to still be active.
    CADENCES = [
      { name: "weekly",     gap: 7,   low: 5,   high: 10,  min: 6, recency: 24 },
      { name: "monthly",    gap: 30,  low: 24,  high: 38,  min: 4, recency: 55 },
      { name: "quarterly",  gap: 91,  low: 78,  high: 104, min: 3, recency: 135 },
      { name: "semiannual", gap: 182, low: 150, high: 210, min: 2, recency: 260 },
      { name: "annual",     gap: 365, low: 320, high: 410, min: 2, recency: 430 }
    ].freeze
    CADENCE_BY_NAME = CADENCES.index_by { |c| c[:name] }.freeze

    # Corporate/legal and address-noise tokens dropped when canonicalizing a
    # vendor name so "Hetzner Online GmbH" and "Hetzner" collapse together.
    NOISE_TOKENS = %w[gmbh ag ug kg se co ltd inc llc bv sarl sca cie et mbh kgaa ohg eg com de wholesale online].freeze

    attr_reader :family

    def initialize(family)
      @family = family
    end

    # Seeds detected contracts and returns the number created.
    def identify
      candidates = build_blocks
      apply_price_changes(candidates)
      candidates.reject! { |c| stale?(c) }
      persist(dedupe(candidates))
    end

    private
      # One block per vendor + account + currency + exact amount that recurs on a
      # cadence. Recency is deferred to after price-change continuation so an old
      # price can still be carried forward to a current one.
      def build_blocks
        by_amount = charges.group_by { |c| [ c[:vendor], c[:account_id], c[:currency], c[:amount] ] }

        by_amount.filter_map do |(vendor, account_id, currency, amount), rows|
          next if amount < MIN_AMOUNT

          dates = rows.map { |r| r[:date] }.uniq.sort
          cadence = classify(dates)
          next if cadence.nil?
          next if sparse_coincidence?(cadence, amount, vendor, account_id)

          representative = rows.max_by { |r| [ r[:merchant] ? 1 : 0, r[:date] ] }
          {
            vendor: vendor, account_id: account_id, currency: currency,
            amount: amount, cadence: cadence[:name], gap: cadence[:gap],
            dates: dates, last: dates.last, occurrences: dates.size,
            name: representative[:name],
            merchant_id: rows.map { |r| r[:merchant_id] }.compact.first
          }
        end
      end

      # Extend each block along its cadence grid to absorb a sequential price
      # change. A charge only continues the series if it lands ~one period out
      # (0.6-1.5x the gap); a charge that arrives sooner is a concurrent one. An
      # amount change is only accepted as a price change if the old amount does
      # not recur afterwards (otherwise the two amounts are parallel subs).
      def apply_price_changes(blocks)
        by_vendor = charges.group_by { |c| [ c[:vendor], c[:account_id], c[:currency] ] }

        blocks.each do |block|
          gap = block[:gap]
          prev_last = block[:last]
          future = by_vendor[[ block[:vendor], block[:account_id], block[:currency] ]]
                   .select { |r| r[:date] > block[:last] && r[:amount] >= MIN_AMOUNT }
                   .sort_by { |r| r[:date] }

          future.each do |row|
            delta = (row[:date] - prev_last).to_i
            break if delta > gap * 1.5
            next if delta < gap * 0.6

            if row[:amount] != block[:amount]
              old = block[:amount]
              recurs_later = by_vendor[[ block[:vendor], block[:account_id], block[:currency] ]]
                             .any? { |r| r[:amount] == old && r[:date] > row[:date] }
              break if recurs_later

              block[:previous_amount] = old
            end
            block[:amount] = row[:amount]
            block[:last] = row[:date]
            block[:occurrences] += 1
            prev_last = row[:date]
          end
        end
      end

      # The cadence a set of dates fits (gap window + occurrences + gap
      # consistency), or nil. Recency is applied separately, post-continuation.
      def classify(dates)
        return nil if dates.size < 2

        gaps = dates.each_cons(2).map { |a, b| (b - a).to_i }
        median_gap = median(gaps)
        cadence = CADENCES.find { |c| median_gap.between?(c[:low], c[:high]) }
        return nil if cadence.nil?
        return nil if dates.size < cadence[:min]

        tolerance = (cadence[:gap] * 0.4).round
        consistent = gaps.count { |g| (g - cadence[:gap]).abs <= tolerance }
        return nil if consistent.to_f / gaps.size < 0.6

        cadence
      end

      def sparse_coincidence?(cadence, amount, vendor, account_id)
        return false if cadence[:min] > 2

        amount < SPARSE_MIN_AMOUNT || amount_diversity.fetch([ vendor, account_id ], 0) > RETAIL_DISTINCT_AMOUNTS
      end

      def stale?(block)
        (Date.current - block[:last]).to_i > CADENCE_BY_NAME.fetch(block[:cadence])[:recency]
      end

      # Collapse a price-changed block that also produced a standalone block at
      # its new amount; genuinely concurrent different-amount contracts survive
      # because they differ on the final amount.
      def dedupe(blocks)
        blocks
          .group_by { |b| [ b[:vendor], b[:account_id], b[:currency], b[:cadence], b[:amount] ] }
          .values
          .map { |group| group.max_by { |b| b[:occurrences] } }
      end

      def persist(blocks)
        blocks.count do |block|
          create_detected_contract(
            name: block[:name],
            merchant_id: block[:merchant_id],
            account_id: block[:account_id],
            currency: block[:currency],
            frequency: block[:cadence],
            expected_amount: block[:amount],
            previous_amount: block[:previous_amount],
            expected_day: median(block[:dates].map(&:day)),
            next_due_date: advance(block[:last], block[:cadence])
          )
        end
      end

      # Seed a detected contract unless the family already has one for this
      # vendor + account + currency + cadence. Two guards keep re-scans idempotent
      # without collapsing genuinely concurrent contracts:
      #   - never add next to a user-curated (non-detected) contract for the same
      #     vendor + cadence — the user owns that surface;
      #   - among detected rows, uniqueness includes the amount, so two concurrent
      #     subscriptions from one vendor (e.g. two Apple plans) can both exist,
      #     while a re-scan of the same block is a no-op.
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
        return false if scope.where.not(source: "detected").exists?
        return false if scope.where(source: "detected", expected_amount: attrs[:expected_amount]).exists?

        family.contracts.create!(attrs.merge(source: "detected"))
        true
      end

      # Expense charges over the lookback window as plain hashes, with the vendor
      # canonicalized. Inflow is negative in Sure, so positive-only drops salary
      # and benefits; transfer kinds drop internal moves.
      def charges
        @charges ||= begin
          family.entries
                .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
                .joins("LEFT JOIN merchants ON merchants.id = transactions.merchant_id")
                .where(entryable_type: "Transaction")
                .where("entries.date >= ?", LOOKBACK_MONTHS.months.ago.to_date)
                .where("entries.amount > 0")
                .where.not("transactions.kind": Transaction::TRANSFER_KINDS)
                .pluck("transactions.merchant_id", "merchants.name", "entries.name", "entries.amount", "entries.currency", "entries.account_id", "entries.date")
                .filter_map do |merchant_id, merchant_name, name, amount, currency, account_id, date|
                  display_name = merchant_id ? merchant_name : name
                  vendor = canonicalize(display_name)
                  next if vendor.blank?

                  {
                    merchant_id: merchant_id, merchant: merchant_id.present?,
                    vendor: vendor, name: display_name,
                    amount: amount.round(2), currency: currency,
                    account_id: account_id, date: date
                  }
                end
        end
      end

      # Distinct amounts a vendor bills at a given account — a proxy for "retail"
      # (many amounts) vs "subscription" (one or two).
      def amount_diversity
        @amount_diversity ||= charges
          .group_by { |c| [ c[:vendor], c[:account_id] ] }
          .transform_values { |rows| rows.map { |r| r[:amount] }.uniq.size }
      end

      def canonicalize(name)
        tokens = name.to_s.downcase.tr("äöüß", "aous").gsub(/[^a-z0-9 ]/, " ").split
        tokens = tokens.reject { |t| NOISE_TOKENS.include?(t) || t.length < 3 || t.match?(/\A\d+\z/) }
        tokens.first(2).join(" ")
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

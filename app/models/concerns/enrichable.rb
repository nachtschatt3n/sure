# Enrichable models can have 1+ of their fields enriched by various
# external sources (i.e. Plaid) or internal sources (i.e. Rules)
#
# This module defines how models should, lock, unlock, and edit attributes
# based on the source of the edit.  User edits always take highest precedence.
#
# For example:
#
# If a Rule tells us to set the category to "Groceries", but the user later overrides
# a transaction with a category of "Food", we should not override the category again.
#
module Enrichable
  extend ActiveSupport::Concern

  InvalidAttributeError = Class.new(StandardError)

  # How long a recorded enrichment attempt suppresses a repeat attempt by the
  # same source. Only attempts that changed nothing are recorded (a successful
  # enrichment locks the attribute instead), so this bounds how often an
  # expensive source is re-asked a question it has already declined to answer.
  #
  # Set AI_ENRICHMENT_ATTEMPT_TTL_DAYS=0 to disable the suppression entirely and
  # restore the previous "retry on every pass" behavior without a code change.
  DEFAULT_ENRICHMENT_ATTEMPT_TTL_DAYS = 30

  def self.enrichment_attempt_ttl
    days = Integer(ENV.fetch("AI_ENRICHMENT_ATTEMPT_TTL_DAYS", DEFAULT_ENRICHMENT_ATTEMPT_TTL_DAYS).to_s, 10)
    days.negative? ? DEFAULT_ENRICHMENT_ATTEMPT_TTL_DAYS.days : days.days
  rescue ArgumentError
    DEFAULT_ENRICHMENT_ATTEMPT_TTL_DAYS.days
  end

  included do
    has_many :data_enrichments, as: :enrichable, dependent: :destroy

    scope :enrichable, ->(attrs) {
      attrs = Array(attrs).map(&:to_s)
      json_condition = attrs.each_with_object({}) { |attr, hash| hash[attr] = true }
      where.not(Arel.sql("#{table_name}.locked_attributes ?| array[:keys]"), keys: attrs)
    }
  end

  class_methods do
    # Override in models to define family-scoped query
    def family_scope(family)
      none
    end

    # Excludes records this source already examined without changing anything,
    # within the attempt TTL. Chains after `enrichable`, which has already
    # dropped every record the source enriched successfully (those are locked),
    # so what remains carrying a fresh attempt marker is exactly the set the
    # source looked at and declined.
    #
    # A TTL of zero disables the filter, restoring unbounded retries.
    def without_recent_enrichment_attempt(attrs, source:, ttl: Enrichable.enrichment_attempt_ttl)
      return all if ttl.to_i.zero?

      attempted = DataEnrichment
        .where(enrichable_type: polymorphic_name, source: source)
        .where(attribute_name: Array(attrs).map(&:to_s))
        .where(updated_at: ttl.ago..)
        .select(:enrichable_id)

      where.not(id: attempted)
    end

    # Clears AI-sourced enrichments for every record of this type in the family.
    # Returns the number of cache entries actually removed, not the number of
    # records visited, so callers can report a figure that means something.
    #
    # A single bad record would otherwise abort the sweep and throw away the
    # tally of everything already cleared, so callers may pass a block to handle
    # per-record failures and keep going.
    def clear_ai_cache(family, &on_record_error)
      count = 0
      family_scope(family).find_each do |record|
        count += record.clear_ai_cache
      rescue => e
        raise unless on_record_error

        on_record_error.call(record, e)
      end
      count
    end
  end

  # Convenience method for a single attribute
  def enrich_attribute(attr, value, source:, metadata: {}, ignore_locks: false)
    enrich_attributes({ attr => value }, source:, metadata:, ignore_locks:)
  end

  # Records that `source` examined `attr` and produced no change, so the record
  # can be skipped on the next pass instead of being re-submitted forever.
  #
  # `enrich_attributes` deliberately cannot express this: it drops attributes
  # whose value did not change, so a source that legitimately returns "nothing
  # here" leaves no trace and is asked the same question on every pass.
  #
  # The marker is written with a nil value, both because the attempt produced no
  # value and so `clear_ai_cache` never mistakes it for evidence that this source
  # set the attribute's current value. It is stored as an ordinary
  # DataEnrichment, so clearing a source's cache clears its attempt markers too
  # and makes every suppressed record immediately retryable.
  def record_enrichment_attempt(attr, source:, metadata: {})
    return false if new_record?

    log_enrichment(
      attribute_name: attr.to_s,
      attribute_value: nil,
      source: source,
      metadata: metadata.merge("attempted_at" => Time.current.iso8601)
    )

    true
  end

  # Enriches and logs all attributes that:
  # - Are not locked (unless ignore_locks: true, e.g. an explicit rule re-apply)
  # - Are not ignored
  # - Have changed value from the last saved value
  # Returns true if any attributes were actually changed, false otherwise
  def enrich_attributes(attrs, source:, metadata: {}, ignore_locks: false)
    # Track current values before modification for virtual attributes (like tag_ids)
    current_values = {}
    enrichable_attrs = Array(attrs).reject do |attr_key, attr_value|
      if (locked?(attr_key) && !ignore_locks) || ignored_enrichable_attributes.include?(attr_key)
        true
      else
        # For virtual attributes (like tag_ids), use the getter method
        # For regular attributes, use self[attr_key]
        current_value = if respond_to?(attr_key.to_sym)
          send(attr_key.to_sym)
        else
          self[attr_key.to_s]
        end

        # Normalize arrays for comparison (sort them)
        if current_value.is_a?(Array) && attr_value.is_a?(Array)
          current_values[attr_key] = current_value
          current_value.sort == attr_value.sort
        else
          current_values[attr_key] = current_value
          current_value == attr_value
        end
      end
    end

    return false if enrichable_attrs.empty?

    was_modified = false
    ActiveRecord::Base.transaction do
      enrichable_attrs.each do |attr, value|
        self.send("#{attr}=", value)

        # If it's a new record, this isn't technically an "enrichment".  No logging necessary.
        unless self.new_record?
          log_enrichment(attribute_name: attr, attribute_value: value, source: source, metadata: metadata)
        end
      end

      save

      # For virtual attributes (like tag_ids), previous_changes won't track them
      # So we need to check if the value actually changed by comparing before/after
      if previous_changes.any?
        was_modified = true
      else
        # Check if any virtual attributes changed by comparing current value with what we set
        enrichable_attrs.each do |attr, new_value|
          # Get the current value after save (for virtual attributes, this reflects the change)
          current_value = if respond_to?(attr.to_sym)
            send(attr.to_sym)
          else
            self[attr.to_s]
          end

          old_value = current_values[attr]
          if old_value.is_a?(Array) && new_value.is_a?(Array) && current_value.is_a?(Array)
            was_modified = true if old_value.sort != current_value.sort
          elsif old_value != current_value
            was_modified = true
          end
          break if was_modified
        end
      end
    end

    # Return whether any attributes were actually saved
    was_modified
  end

  def locked?(attr)
    locked_attributes[attr.to_s].present?
  end

  def enrichable?(attr)
    !locked?(attr)
  end

  def lock_attr!(attr)
    update!(locked_attributes: locked_attributes.merge(attr.to_s => Time.current))
  end

  def unlock_attr!(attr)
    update!(locked_attributes: locked_attributes.except(attr.to_s))
  end

  def lock_saved_attributes!
    saved_changes.keys.reject { |attr| ignored_enrichable_attributes.include?(attr) }.each do |attr|
      lock_attr!(attr)
    end
  end

  # Returns the number of AI cache entries removed from this record.
  def clear_ai_cache
    removed_count = 0

    ActiveRecord::Base.transaction do
      ai_enrichments = data_enrichments.where(source: "ai")

      # Only unlock attributes where current value still matches what AI set
      # If user changed the value, they took ownership - don't unlock
      attrs_to_unlock = ai_enrichments.select do |enrichment|
        attr_name = enrichment.attribute_name
        current_value = respond_to?(attr_name) ? send(attr_name) : self[attr_name]
        current_value.to_s == enrichment.value.to_s
      end.map(&:attribute_name).uniq

      # Batch unlock in a single update
      if attrs_to_unlock.any?
        new_locked_attrs = locked_attributes.except(*attrs_to_unlock)
        update_column(:locked_attributes, new_locked_attrs) if new_locked_attrs != locked_attributes
      end

      # Delete AI enrichment records
      removed_count = ai_enrichments.delete_all
    end

    removed_count
  end

  private
    def log_enrichment(attribute_name:, attribute_value:, source:, metadata: {})
      de = DataEnrichment.find_or_create_by(
        enrichable: self,
        attribute_name: attribute_name,
        source: source,
      )

      de.value = attribute_value
      de.metadata = metadata
      de.save
    end

    def ignored_enrichable_attributes
      %w[id updated_at created_at]
    end
end

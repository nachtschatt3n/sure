require "test_helper"

class EnrichableTest < ActiveSupport::TestCase
  setup do
    @enrichable = accounts(:depository)
  end

  test "can enrich multiple attributes" do
    assert_difference "DataEnrichment.count", 2 do
      @enrichable.enrich_attributes({ name: "Updated Checking", balance: 6_000 }, source: "plaid")
    end

    assert_equal "Updated Checking", @enrichable.name
    assert_equal 6_000, @enrichable.balance.to_d
  end

  test "can enrich a single attribute" do
    assert_difference "DataEnrichment.count", 1 do
      @enrichable.enrich_attribute(:name, "Single Update", source: "ai")
    end

    assert_equal "Single Update", @enrichable.name
  end

  test "can lock an attribute" do
    refute @enrichable.locked?(:name)

    @enrichable.lock_attr!(:name)
    assert @enrichable.locked?(:name)
  end

  test "can unlock an attribute" do
    @enrichable.lock_attr!(:name)
    assert @enrichable.locked?(:name)

    @enrichable.unlock_attr!(:name)
    refute @enrichable.locked?(:name)
  end

  test "can lock saved attributes" do
    @enrichable.name = "User Override"
    @enrichable.balance = 1_234
    @enrichable.save!

    @enrichable.lock_saved_attributes!

    assert @enrichable.locked?(:name)
    assert @enrichable.locked?(:balance)
  end

  test "does not enrich locked attributes" do
    original_name = @enrichable.name

    @enrichable.lock_attr!(:name)

    assert_no_difference "DataEnrichment.count" do
      @enrichable.enrich_attribute(:name, "Should Not Change", source: "plaid")
    end

    assert_equal original_name, @enrichable.reload.name
  end

  test "enrichable? reflects lock state" do
    assert @enrichable.enrichable?(:name)

    @enrichable.lock_attr!(:name)

    refute @enrichable.enrichable?(:name)
  end

  test "enrichable scope includes and excludes records based on lock state" do
    # Initially, the record should be enrichable for :name
    assert_includes Account.enrichable(:name), @enrichable

    @enrichable.lock_attr!(:name)

    refute_includes Account.enrichable(:name), @enrichable
  end

  test "recording an enrichment attempt logs a nil-valued marker without changing the attribute" do
    original_name = @enrichable.name

    assert_difference "DataEnrichment.count", 1 do
      @enrichable.record_enrichment_attempt(:name, source: "ai", metadata: { "reason" => "no_match" })
    end

    marker = DataEnrichment.find_by(enrichable: @enrichable, attribute_name: "name", source: "ai")

    assert_nil marker.value
    assert_equal "no_match", marker.metadata["reason"]
    assert marker.metadata["attempted_at"].present?

    # The attempt must not touch the record or its lock state
    assert_equal original_name, @enrichable.reload.name
    refute @enrichable.locked?(:name)
  end

  test "repeated attempts reuse the single marker row" do
    @enrichable.record_enrichment_attempt(:name, source: "ai")

    assert_no_difference "DataEnrichment.count" do
      @enrichable.record_enrichment_attempt(:name, source: "ai")
    end
  end

  test "without_recent_enrichment_attempt excludes recently attempted records" do
    assert_includes Account.without_recent_enrichment_attempt(:name, source: "ai"), @enrichable

    @enrichable.record_enrichment_attempt(:name, source: "ai")

    refute_includes Account.without_recent_enrichment_attempt(:name, source: "ai"), @enrichable
  end

  test "without_recent_enrichment_attempt readmits records once the attempt ages out" do
    @enrichable.record_enrichment_attempt(:name, source: "ai")

    travel_to (Enrichable::DEFAULT_ENRICHMENT_ATTEMPT_TTL_DAYS + 1).days.from_now do
      assert_includes Account.without_recent_enrichment_attempt(:name, source: "ai"), @enrichable
    end
  end

  test "without_recent_enrichment_attempt is scoped by source and attribute" do
    @enrichable.record_enrichment_attempt(:name, source: "ai")

    # A different source has not attempted this attribute
    assert_includes Account.without_recent_enrichment_attempt(:name, source: "plaid"), @enrichable

    # ...and this source has not attempted a different attribute
    assert_includes Account.without_recent_enrichment_attempt(:balance, source: "ai"), @enrichable
  end

  test "a zero ttl disables attempt suppression entirely" do
    @enrichable.record_enrichment_attempt(:name, source: "ai")

    assert_includes Account.without_recent_enrichment_attempt(:name, source: "ai", ttl: 0), @enrichable
  end
end

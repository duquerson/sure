require "test_helper"

class Insight::GeneratorRegistryTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  # Every type a registered generator can produce must be a valid Insight type,
  # or the job's create! would raise for it in production.
  test "every produced type is a valid insight type" do
    produced = Insight::GeneratorRegistry::GENERATORS.flat_map(&:produced_types)

    assert_empty produced - Insight::TYPES
  end

  test "a failing new generator is logged and skipped, and the others still run" do
    Insight::Generators::SpendingPaceGenerator.any_instance.stubs(:generate).raises(StandardError, "boom")
    survivor = Insight::Generator::GeneratedInsight.new(
      insight_type: "top_movers", priority: "low", title: "t", template_key: "top_movers.up", facts: {}, metadata: {},
      currency: "USD", period_start: nil, period_end: nil, dedup_key: "top_movers:test"
    )
    Insight::Generators::TopMoversGenerator.any_instance.stubs(:generate).returns([ survivor ])

    result = nil
    assert_difference "DebugLogEntry.count", 1 do
      result = Insight::GeneratorRegistry.new(@family).generate_all
    end

    assert_includes result.insights, survivor
    assert_not_includes result.succeeded_types, "spending_pace"
    assert_includes result.succeeded_types, "top_movers"
  end
end

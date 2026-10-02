require "test_helper"

# A regex rule runs under a statement timeout. The matching ids are resolved
# inside that bound and the actions then run on those ids, so the unbounded part
# of the rule (the pattern) is the only part that is limited.
class Rule::RegexExecutionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Regex run", balance: 1000, currency: "USD", accountable: Depository.new)
    @category = @family.categories.create!(name: "Shopping")
    @hit = create_transaction(date: Date.current, account: @account, name: "AMZN Mktp US")
    @miss = create_transaction(date: Date.current, account: @account, name: "Corner shop")
  end

  test "a regex rule applies to the matching rows only" do
    rule = regex_rule('^amzn\s')

    assert_equal 1, rule.apply

    assert_equal @category, @hit.reload.transaction.category
    assert_nil @miss.reload.transaction.category
  end

  test "a regex rule resolves its matches under the timeout" do
    rule = regex_rule("amzn")

    Rule::SafeRegex.expects(:with_timeout).yields.once

    rule.apply
  end

  test "a rule without a regex condition does not use the timeout" do
    rule = Rule.create!(
      family: @family, resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "amzn") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @category.id) ]
    )

    Rule::SafeRegex.expects(:with_timeout).never

    assert_equal 1, rule.apply
  end

  # Each action reads the matches again, so without a cache a broad pattern is scanned
  # (and materialised) once per action, each time paying the timeout in the worst case.
  test "a regex is resolved once per apply however many actions the rule has" do
    rule = Rule.create!(
      family: @family, resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "matches_regex", value: "amzn") ],
      actions: [
        Rule::Action.new(action_type: "set_transaction_category", value: @category.id),
        Rule::Action.new(action_type: "exclude_transaction")
      ]
    )
    calls = 0
    Rule::SafeRegex.stubs(:with_timeout).with { |*| calls += 1; true }.yields.returns([ @hit.transaction.id ])

    rule.apply

    assert_equal 1, calls
    assert_equal @category, @hit.reload.transaction.category
    assert @hit.reload.excluded?, "the second action ran on the resolved match"
  end

  test "the cache lasts for one apply: a later apply resolves the pattern again" do
    rule = regex_rule("amzn")
    calls = 0
    Rule::SafeRegex.stubs(:with_timeout).with { |*| calls += 1; true }.yields.returns([ @hit.transaction.id ])

    rule.apply
    rule.apply

    assert_equal 2, calls
  end

  test "a regex inside a compound condition is also bounded" do
    rule = Rule.new(family: @family, resource_type: "transaction",
                    actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @category.id) ])
    compound = rule.conditions.build(condition_type: "compound", operator: "or")
    compound.sub_conditions.build(condition_type: "transaction_name", operator: "matches_regex", value: "amzn")
    rule.save!

    Rule::SafeRegex.expects(:with_timeout).yields.once

    rule.apply
  end

  test "a timeout is raised from apply so the run is recorded as failed" do
    rule = regex_rule("amzn")
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_raises(Rule::SafeRegex::TimeoutError) { rule.apply }

    assert_nil @hit.reload.transaction.category
  end

  test "RuleJob records a failed run when the pattern times out" do
    rule = regex_rule("amzn")
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_difference -> { rule.rule_runs.where(status: "failed").count }, 1 do
      assert_raises(Rule::SafeRegex::TimeoutError) { RuleJob.perform_now(rule) }
    end
  end

  test "the confirmation counts are 0 rather than an error when the pattern times out" do
    rule = regex_rule("amzn")
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_equal 0, rule.affected_resource_count
    assert_equal 0, Rule.total_affected_resource_count([ rule ])
  end

  test "ApplyAllRulesJob carries on with the next rule after one times out" do
    slow = regex_rule("amzn", name: "slow")
    fine = Rule.create!(
      family: @family, resource_type: "transaction", name: "fine",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "shop") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @category.id) ]
    )
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    assert_nothing_raised { ApplyAllRulesJob.perform_now(@family) }

    assert_equal 1, slow.rule_runs.where(status: "failed").count
    assert_equal 1, fine.rule_runs.where(status: "success").count
    assert_equal @category, @miss.reload.transaction.category
  end

  test "an email-notification action whose baseline times out is still created, and the rule is switched off" do
    rule = regex_rule("amzn")
    rule.update!(active: true)
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    # after_create_commit does not fire under transactional tests, so the seeding
    # path is invoked directly (as send_email_notification_test.rb does).
    action = rule.actions.create!(action_type: "send_email_notification")
    assert_nothing_raised { action.send(:seed_notification_baseline) }

    # No baseline was recorded, so leaving the rule on would email every past match.
    assert_not rule.reload.active?
    assert_equal 0, NotificationDelivery.where(rule_id: rule.id).count
    assert action.persisted?
  end

  private
    def regex_rule(pattern, name: nil)
      Rule.create!(
        family: @family, resource_type: "transaction", name: name,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "matches_regex", value: pattern) ],
        actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @category.id) ]
      )
    end
end

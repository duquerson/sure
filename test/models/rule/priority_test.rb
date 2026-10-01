require "test_helper"

# Rules run in an order the user can see and change. Every runner uses the same
# one, so the outcome of two rules matching one transaction is a function of
# that order and of nothing else.
class Rule::PriorityTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include ActiveJob::TestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Priority", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries")
    @dining = @family.categories.create!(name: "Dining")
    @entry = create_transaction(date: Date.current, account: @account, name: "Whole Foods Market")
  end

  test "a new rule goes to the end of its family's order" do
    first = rule_setting(@groceries, name: "first")
    second = rule_setting(@dining, name: "second")

    assert_equal first.priority + 1, second.priority
    assert_equal [ first, second ], @family.rules.prioritised.to_a
  end

  test "another family's rules do not count towards the next priority" do
    rule_setting(@groceries)
    other = families(:dylan_family).rules.create!(
      resource_type: "transaction", actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    assert_equal 1, other.priority - families(:dylan_family).rules.where.not(id: other.id).maximum(:priority).to_i
  end

  test "prioritised is a total order: equal priorities fall back to created_at, then id" do
    older = rule_setting(@groceries, name: "older")
    newer = rule_setting(@dining, name: "newer")
    older.update_columns(priority: 5, created_at: 2.days.ago)
    newer.update_columns(priority: 5, created_at: 1.day.ago)

    assert_equal [ older, newer ], @family.rules.prioritised.to_a

    newer.update_columns(created_at: older.created_at)
    expected = [ older, newer ].sort_by(&:id)

    assert_equal expected, @family.rules.prioritised.to_a
  end

  test "move up and down swap a rule with its neighbour" do
    a = rule_setting(@groceries, name: "a")
    b = rule_setting(@dining, name: "b")
    c = rule_setting(@groceries, name: "c")

    c.move(:up)
    assert_equal [ a, c, b ], @family.rules.prioritised.to_a

    a.move(:down)
    assert_equal [ c, a, b ], @family.rules.prioritised.to_a
  end

  test "moving the first rule up, or the last rule down, changes nothing" do
    a = rule_setting(@groceries, name: "a")
    b = rule_setting(@dining, name: "b")

    assert_no_changes -> { @family.rules.prioritised.map(&:id) } do
      a.move(:up)
      b.move(:down)
    end
  end

  test "move repairs rules that share a priority" do
    a = rule_setting(@groceries, name: "a")
    b = rule_setting(@dining, name: "b")
    a.update_columns(priority: 0, created_at: 2.days.ago)
    b.update_columns(priority: 0, created_at: 1.day.ago)

    b.move(:up)

    assert_equal [ b, a ], @family.rules.prioritised.to_a
  end

  test "move rejects a direction it does not know" do
    assert_raises(ArgumentError) { rule_setting(@groceries).move(:sideways) }
  end

  test "move leaves another family's rules alone" do
    mine = rule_setting(@groceries)
    theirs = families(:dylan_family).rules.create!(
      resource_type: "transaction", actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    assert_no_changes -> { theirs.reload.priority } do
      mine.move(:down)
    end
  end

  test "the later rule wins when locks are ignored, and reordering changes the outcome" do
    first = rule_setting(@groceries, name: "first")
    second = rule_setting(@dining, name: "second")

    ApplyAllRulesJob.perform_now(@family)
    assert_equal @dining, category_of(@entry)

    second.move(:up)
    @entry.transaction.update_columns(category_id: nil)
    @entry.transaction.update!(locked_attributes: {})
    ApplyAllRulesJob.perform_now(@family)

    assert_equal @groceries, category_of(@entry)
    assert_equal [ second, first ], @family.rules.prioritised.to_a
  end

  # Rule actions do not lock what they write (only user edits and AI categorisation
  # do), so with locks respected a later rule still overwrites an earlier one.
  test "the later rule wins when locks are respected, and reordering changes the outcome" do
    first = rule_setting(@groceries, name: "first", active: true)
    second = rule_setting(@dining, name: "second", active: true)

    ApplyAllRulesJob.perform_now(@family, active_only: true, ignore_attribute_locks: false)
    assert_equal @dining, category_of(@entry)

    second.move(:up)
    ApplyAllRulesJob.perform_now(@family, active_only: true, ignore_attribute_locks: false)

    assert_equal @groceries, category_of(@entry)
  end

  # Rewriting a row moves it in the table, so a test that reorders through #move can
  # pass on physical order alone. Here the row written last has the lowest priority.
  test "rules run by priority, not by creation or physical order" do
    first = rule_setting(@groceries, name: "first", active: true)
    second = rule_setting(@dining, name: "second", active: true)
    first.update_columns(priority: 2)
    second.update_columns(priority: 1)

    ApplyAllRulesJob.perform_now(@family, active_only: true, ignore_attribute_locks: false)

    assert_equal [ second, first ], @family.rules.prioritised.to_a
    assert_equal @groceries, category_of(@entry)
  end

  test "a category the user locked is not overwritten by either order" do
    rule_setting(@groceries, name: "first", active: true)
    rule_setting(@dining, name: "second", active: true)
    @entry.transaction.update!(category: @groceries)
    @entry.transaction.lock_attr!(:category_id)

    ApplyAllRulesJob.perform_now(@family, active_only: true, ignore_attribute_locks: false)

    assert_equal @groceries, category_of(@entry)
  end

  test "active_only skips rules that are switched off" do
    rule_setting(@groceries, name: "off", active: false)
    live = rule_setting(@dining, name: "on", active: true)

    RuleJob.expects(:perform_now).with(live, ignore_attribute_locks: false, execution_type: "manual").once

    ApplyAllRulesJob.perform_now(@family, active_only: true, ignore_attribute_locks: false)
  end

  test "a rule that fails does not stop the ones after it, and the job still fails so it can be retried" do
    first = rule_setting(@groceries, name: "first", active: true)
    second = rule_setting(@dining, name: "second", active: true)
    RuleJob.stubs(:perform_now).with(first, anything).raises(ActiveRecord::StatementInvalid.new("transient"))
    RuleJob.expects(:perform_now).with(second, anything).once

    assert_raises(ActiveRecord::StatementInvalid) do
      ApplyAllRulesJob.perform_now(@family, active_only: true, ignore_attribute_locks: false)
    end
  end

  test "a regex timeout is final: later rules run and the job does not fail" do
    first = rule_setting(@groceries, name: "first", active: true)
    second = rule_setting(@dining, name: "second", active: true)
    RuleJob.stubs(:perform_now).with(first, anything).raises(Rule::SafeRegex::TimeoutError)
    RuleJob.expects(:perform_now).with(second, anything).once

    assert_nothing_raised do
      ApplyAllRulesJob.perform_now(@family, active_only: true, ignore_attribute_locks: false)
    end
  end

  # Tests share one connection, so a second session has to be opened by hand for the
  # lock to mean anything.
  test "passes for one family are serialised by a lock the job holds while it runs" do
    rule_setting(@groceries, active: true)
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    other_session = PG.connect(
      host: config[:host], port: config[:port], dbname: config[:database],
      user: config[:username], password: config[:password]
    )
    key = ApplyAllRulesJob.lock_key(@family)
    try_lock = -> { other_session.exec_params("SELECT pg_try_advisory_lock($1)", [ key ]).getvalue(0, 0) == "t" }

    held_during = nil
    RuleJob.stubs(:perform_now).with { held_during = !try_lock.call; true }

    ApplyAllRulesJob.perform_now(@family, active_only: true, ignore_attribute_locks: false)

    assert held_during, "another session could take the family's lock while the pass was running"
    assert try_lock.call, "the lock was still held after the pass finished"
  ensure
    other_session&.close
  end

  test "the post-sync pass enqueues one ordered job, not one job per rule" do
    rule_setting(@groceries, active: true)
    rule_setting(@dining, active: true)

    assert_enqueued_jobs 1, only: ApplyAllRulesJob do
      assert_no_enqueued_jobs only: RuleJob do
        Family::Syncer.new(@family).perform_post_sync
      end
    end
  end

  test "an existing rule database is backfilled oldest first, per family" do
    Rule.reset_column_information
    a = rule_setting(@groceries, name: "a")
    b = rule_setting(@dining, name: "b")
    other = families(:dylan_family).rules.create!(
      resource_type: "transaction", actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )
    a.update_columns(created_at: 3.days.ago)
    b.update_columns(created_at: 4.days.ago)
    other.update_columns(created_at: 1.day.ago)

    connection = ActiveRecord::Base.connection
    connection.remove_index :rules, [ :family_id, :priority ]
    connection.remove_column :rules, :priority
    require Rails.root.join("db/migrate/20261001090000_add_priority_to_rules")
    AddPriorityToRules.new.up

    priorities = connection.select_rows("SELECT id, priority FROM rules WHERE id IN ('#{a.id}', '#{b.id}', '#{other.id}')").to_h
    assert_equal 1, priorities[b.id]
    assert_equal 2, priorities[a.id]
    assert_equal 1, priorities[other.id]
  ensure
    Rule.reset_column_information
  end

  private
    def rule_setting(category, name: nil, active: false)
      @family.rules.create!(
        resource_type: "transaction", name: name, active: active,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "whole foods") ],
        actions: [ Rule::Action.new(action_type: "set_transaction_category", value: category.id) ]
      )
    end

    def category_of(entry)
      entry.transaction.reload.category
    end
end

class ApplyAllRulesJob < ApplicationJob
  queue_as :medium_priority

  # @param family [Family]
  # @return [Integer] the Postgres advisory lock key shared by every pass for the family
  def self.lock_key(family)
    Digest::SHA256.hexdigest("apply_all_rules:#{family.id}").to_i(16) % (2**62)
  end

  # @param family [Family]
  # @param execution_type [String] a RuleRun execution type
  # @param active_only [Boolean] skip rules that are switched off
  # @param ignore_attribute_locks [Boolean] whether a rule may overwrite an attribute a
  #   user or an earlier rule locked
  def perform(family, execution_type: "manual", active_only: false, ignore_attribute_locks: true)
    rules = active_only ? family.rules.where(active: true) : family.rules

    # Two passes for one family would interleave their rules and break the order, so
    # the second waits for the first.
    with_family_lock(family) do
      Rule.apply_in_priority_order(rules, ignore_attribute_locks: ignore_attribute_locks, execution_type: execution_type)
    end
  end

  private
    def with_family_lock(family)
      key = self.class.lock_key(family)
      connection = ActiveRecord::Base.connection
      connection.execute(ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_lock(?)", key ]))

      begin
        yield
      ensure
        connection.execute(ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", key ]))
      end
    end
end

class ApplyAllRulesJob < ApplicationJob
  queue_as :medium_priority

  # How long a pass that finds another one running for the family waits before trying.
  LOCK_RETRY_DELAY = 30.seconds

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

    # Two passes for one family would interleave their rules and break the order. The
    # second does not hold a worker thread while it waits: it puts itself back on the
    # queue and tries again later.
    acquired = with_family_lock(family) do
      Rule.apply_in_priority_order(rules, ignore_attribute_locks: ignore_attribute_locks, execution_type: execution_type)
    end

    return if acquired

    self.class.set(wait: LOCK_RETRY_DELAY).perform_later(
      family, execution_type: execution_type, active_only: active_only, ignore_attribute_locks: ignore_attribute_locks
    )
  end

  private
    # @return [Boolean] false, without yielding, when another pass holds the lock
    def with_family_lock(family)
      key = self.class.lock_key(family)
      connection = ActiveRecord::Base.connection
      acquired = connection.select_value(ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", key ]))
      return false unless acquired

      begin
        yield
      ensure
        connection.execute(ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", key ]))
      end

      true
    end
end

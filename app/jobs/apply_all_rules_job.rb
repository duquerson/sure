class ApplyAllRulesJob < ApplicationJob
  queue_as :medium_priority

  # @param family [Family]
  # @param execution_type [String] a RuleRun execution type
  # @param active_only [Boolean] skip rules that are switched off
  # @param ignore_attribute_locks [Boolean] whether a rule may overwrite an attribute a
  #   user or an earlier rule locked
  def perform(family, execution_type: "manual", active_only: false, ignore_attribute_locks: true)
    rules = active_only ? family.rules.where(active: true) : family.rules

    Rule.apply_in_priority_order(rules, ignore_attribute_locks: ignore_attribute_locks, execution_type: execution_type)
  end
end

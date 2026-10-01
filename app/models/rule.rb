class Rule < ApplicationRecord
  UnsupportedResourceTypeError = Class.new(StandardError)

  MOVE_DIRECTIONS = %i[up down].freeze

  belongs_to :family
  has_many :conditions, dependent: :destroy
  has_many :actions, dependent: :destroy
  has_many :rule_runs, dependent: :destroy

  accepts_nested_attributes_for :conditions, allow_destroy: true
  accepts_nested_attributes_for :actions, allow_destroy: true

  before_validation :normalize_name
  before_validation :assign_priority, on: :create

  # The order every runner applies rules in. Priority alone is not unique (rules
  # imported or edited by hand can share one), so created_at and id make it a
  # total order: the same rules always run in the same sequence.
  scope :prioritised, -> { order(:priority, :created_at, :id) }

  validates :resource_type, presence: true
  validates :name, length: { minimum: 1 }, allow_nil: true
  validate :no_nested_compound_conditions

  # Every rule must have at least 1 action
  validate :min_actions
  validate :no_duplicate_actions

  # Applies a family's rules one after another in priority order.
  #
  # Order only means something if the rules run one at a time: with attribute
  # locks respected the first rule to set an attribute wins, and with locks
  # ignored the last one does. A rule that fails has already recorded a failed
  # RuleRun, so the rest still run.
  #
  # @param rules [ActiveRecord::Relation] rules of one family
  # @param ignore_attribute_locks [Boolean]
  # @param execution_type [String] a RuleRun execution type
  def self.apply_in_priority_order(rules, ignore_attribute_locks:, execution_type:)
    rules.prioritised.each do |rule|
      RuleJob.perform_now(rule, ignore_attribute_locks: ignore_attribute_locks, execution_type: execution_type)
    rescue => e
      Rails.logger.error("Rule #{rule.id} failed during an ordered run: #{e.class}: #{e.message}")
    end
  end

  # Swaps this rule with its neighbour in the family's order.
  #
  # Positions are rewritten densely (1, 2, 3...) rather than swapped, which also
  # repairs rules that share a priority. Rules at the edge stay where they are.
  #
  # @param direction [Symbol] :up (runs earlier) or :down (runs later)
  def move(direction)
    direction = direction.to_sym
    raise ArgumentError, "Unknown direction: #{direction}" unless MOVE_DIRECTIONS.include?(direction)

    self.class.transaction do
      family.lock!
      ordered = family.rules.prioritised.to_a
      index = ordered.index { |rule| rule.id == id }
      neighbour = direction == :up ? index - 1 : index + 1

      if neighbour >= 0 && neighbour < ordered.size
        ordered[index], ordered[neighbour] = ordered[neighbour], ordered[index]
      end

      ordered.each.with_index(1) do |rule, position|
        rule.update_column(:priority, position) unless rule.priority == position
      end
    end

    reload
  end

  def action_executors
    registry.action_executors
  end

  def condition_filters
    registry.condition_filters
  end

  def registry
    @registry ||= case resource_type
    when "transaction"
      Rule::Registry::TransactionResource.new(self)
    else
      raise UnsupportedResourceTypeError, "Unsupported resource type: #{resource_type}"
    end
  end

  # Display-only: a pattern that times out reads as zero here, and the failure
  # surfaces where the rule actually runs (#apply).
  def affected_resource_count
    matching_resources_scope.count
  rescue Rule::SafeRegex::TimeoutError
    0
  end

  # Public wrapper around the private matching scope so callers can read the
  # currently-matching transaction ids WITHOUT running executors (e.g. the
  # notification baseline pre-seed). Mirrors total_affected_resource_count,
  # which also reaches matching_resources_scope.
  def matching_transaction_ids
    matching_resources_scope.pluck(:id)
  end

  # Creates a categorization rule for the Quick Categorize Wizard.
  # Returns the saved rule, or nil if a duplicate or invalid rule already exists.
  def self.create_from_grouping(family, grouping_key, category, transaction_type: nil)
    rule = family.rules.build(name: grouping_key, resource_type: "transaction", active: true)
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: grouping_key)
    rule.conditions.build(condition_type: "transaction_type", operator: "=", value: transaction_type) if transaction_type.present?
    rule.actions.build(action_type: "set_transaction_category", value: category.id.to_s)
    rule.save!
    rule
  rescue ActiveRecord::RecordInvalid
    nil
  end

  # Calculates total unique resources affected across multiple rules
  # This handles overlapping rules by deduplicating transaction IDs
  def self.total_affected_resource_count(rules)
    return 0 if rules.empty?

    # Collect all unique transaction IDs matched by any rule
    transaction_ids = Set.new
    rules.each do |rule|
      transaction_ids.merge(rule.send(:matching_resources_scope).pluck(:id))
    rescue Rule::SafeRegex::TimeoutError
      next
    end

    transaction_ids.size
  end

  def apply(ignore_attribute_locks: false, rule_run: nil)
    total_modified = 0
    total_async_jobs = 0
    has_async = false

    actions.each do |action|
      result = action.apply(matching_resources_scope, ignore_attribute_locks: ignore_attribute_locks, rule_run: rule_run)

      if result.is_a?(Hash) && result[:async]
        has_async = true
        total_async_jobs += result[:jobs_count] || 0
        total_modified += result[:modified_count] || 0
      elsif result.is_a?(Integer)
        total_modified += result
      else
        # Log unexpected result type but don't fail
        Rails.logger.warn("Rule#apply: Unexpected result type from action #{action.id}: #{result.class} (value: #{result.inspect})")
      end
    end

    if has_async
      { modified_count: total_modified, async: true, jobs_count: total_async_jobs }
    else
      total_modified
    end
  end

  def apply_later(ignore_attribute_locks: false)
    RuleJob.perform_later(self, ignore_attribute_locks: ignore_attribute_locks)
  end

  def primary_condition_title
    condition = displayed_condition
    return I18n.t("rules.no_condition") if condition.blank?

    "If #{condition.filter.label.downcase} #{condition.operator} #{condition.value_display}"
  end

  def displayed_condition
    displayable_conditions.first
  end

  def additional_displayable_conditions_count
    [ displayable_conditions.size - 1, 0 ].max
  end

  def displayable_conditions
    conditions.filter_map do |condition|
      condition.compound? ? condition.sub_conditions.first : condition
    end
  end

  private
    def matching_resources_scope
      scope = registry.resource_scope

      # 1. Prepare the query with joins required by conditions
      conditions.each do |condition|
        scope = condition.prepare(scope)
      end

      # 2. Apply the conditions to the query
      conditions.each do |condition|
        scope = condition.apply(scope)
      end

      # A pattern is the one condition whose cost the database cannot bound by
      # itself, so its matches are resolved under a statement timeout and the
      # actions then run on those ids.
      return scope unless conditions.any?(&:uses_regex?)

      ids = Rule::SafeRegex.with_timeout { scope.pluck(:id) }
      registry.resource_scope.where(id: ids)
    end

    def min_actions
      return if new_record? && !actions.empty?

      if actions.reject(&:marked_for_destruction?).empty?
        errors.add(:base, :min_actions)
      end
    end

    def no_duplicate_actions
      action_types = actions.reject(&:marked_for_destruction?).map(&:action_type)

      errors.add(:base, :duplicate_actions, types: action_types.inspect) if action_types.uniq.count != action_types.count
    end

    # Validation: To keep rules simple and easy to understand, we don't allow nested compound conditions.
    def no_nested_compound_conditions
      return true if conditions.none? { |condition| condition.compound? }

      conditions.each do |condition|
        if condition.compound?
          if condition.sub_conditions.any? { |sub_condition| sub_condition.compound? }
            errors.add(:base, :nested_conditions)
          end
        end
      end
    end

    def assign_priority
      return if priority.to_i.positive? || family.nil?

      self.priority = (family.rules.maximum(:priority) || 0) + 1
    end

    def normalize_name
      self.name = nil if name.is_a?(String) && name.strip.empty?
    end
end

require "test_helper"

class RetirementPlanTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
    RetirementPlan.where(user: [ @admin, @member ]).delete_all
  end

  test "a user with no saved plan gets the defaults, and nothing is written" do
    assert_no_difference "RetirementPlan.count" do
      plan = RetirementPlan.for(@admin)

      assert plan.new_record?
      assert_equal @admin, plan.user
      assert_equal BigDecimal("0.04"), plan.safe_withdrawal_rate
      assert_equal BigDecimal("0.05"), plan.expected_annual_return
      assert_nil plan.savings_rate
      assert_nil plan.retirement_date
    end
  end

  test "a user's saved plan is the one returned" do
    saved = RetirementPlan.create!(user: @admin, safe_withdrawal_rate: BigDecimal("0.035"))

    assert_equal saved, RetirementPlan.for(@admin)
    assert RetirementPlan.for(@member).new_record?
  end

  test "a withdrawal rate of zero, above one, or blank is refused" do
    [ 0, BigDecimal("1.5"), nil ].each do |rate|
      plan = RetirementPlan.new(user: @admin, safe_withdrawal_rate: rate)

      assert_not plan.valid?, "#{rate.inspect} should be refused"
      assert plan.errors.key?(:safe_withdrawal_rate)
    end
    assert RetirementPlan.new(user: @admin, safe_withdrawal_rate: 1).valid?
  end

  test "a return of -100% or less, or above 100%, is refused" do
    [ -1, BigDecimal("1.01") ].each do |rate|
      assert_not RetirementPlan.new(user: @admin, expected_annual_return: rate).valid?, "#{rate} should be refused"
    end
    assert RetirementPlan.new(user: @admin, expected_annual_return: BigDecimal("-0.99")).valid?
  end

  test "a savings rate outside 0 to 100% is refused, and a blank one means derive it" do
    assert_not RetirementPlan.new(user: @admin, savings_rate: BigDecimal("-0.01")).valid?
    assert_not RetirementPlan.new(user: @admin, savings_rate: BigDecimal("1.01")).valid?
    assert RetirementPlan.new(user: @admin, savings_rate: nil).valid?
    assert RetirementPlan.new(user: @admin, savings_rate: 0).valid?
  end

  test "the database refuses a withdrawal rate of zero that bypasses the model" do
    plan = RetirementPlan.create!(user: @admin)

    assert_raises(ActiveRecord::StatementInvalid) { plan.update_columns(safe_withdrawal_rate: 0) }
  end

  test "one plan per user" do
    RetirementPlan.create!(user: @admin)

    assert_raises(ActiveRecord::RecordNotUnique) { RetirementPlan.new(user: @admin).save!(validate: false) }
  end

  test "deleting the user deletes their plan" do
    RetirementPlan.create!(user: @member)

    assert_difference "RetirementPlan.count", -1 do
      @member.destroy
    end
  end
end

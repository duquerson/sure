require "test_helper"

class Spending::NarrativeTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # Mid-month in a month no fixture touches.
  TODAY = Date.new(2024, 3, 14)

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
  end

  def narrative(on: TODAY, family: @family, user: @user)
    Spending::Narrative.new(family: family, user: user, on: on)
  end

  def create_budget(user: nil, budgeted: 1000, start_date: Date.new(2024, 3, 1))
    Budget.create!(family: @family, user: user, start_date: start_date, end_date: start_date.end_of_month,
                   budgeted_spending: budgeted, expected_income: 0, currency: "USD")
  end

  test "the period runs from the start of the month to the injected date" do
    period = narrative.period

    assert_equal Date.new(2024, 3, 1), period.start_date
    assert_equal TODAY, period.end_date
  end

  test "a family with a custom month start gets its own month" do
    @family.update!(month_start_day: 10)

    period = narrative.period

    assert_equal Date.new(2024, 3, 10), period.start_date
    assert_equal TODAY, period.end_date
  end

  test "the previous period is the equal-length window before it" do
    previous = narrative.previous_period

    assert_equal narrative.period.days, previous.days
    assert_equal narrative.period.start_date - 1.day, previous.end_date
  end

  test "the budget is the one covering the date, found without creating anything" do
    budget = create_budget

    assert_equal budget, narrative.budget
    assert_no_difference "Budget.count" do
      narrative(on: Date.new(2023, 1, 10)).budget
    end
    assert_nil narrative(on: Date.new(2023, 1, 10)).budget
  end

  test "pace is nil when there is no budget, and the rest of the page still works" do
    result = narrative(on: Date.new(2023, 1, 10))

    assert_nil result.pace
    assert_equal 0, result.heatmap.total
    assert_equal [], result.top_movers
  end

  test "pace is computed against the injected date" do
    create_budget(budgeted: 1000)
    create_transaction(amount: 600, date: Date.new(2024, 3, 3), name: "Narrative spend")

    # 14 of 31 days elapsed: 600 of 1000 is well ahead of pace.
    assert_equal :approaching, narrative(on: Date.new(2024, 3, 14)).pace.status
    # 31 of 31: the same 600 is comfortably inside the budget.
    assert_equal :on_track, narrative(on: Date.new(2024, 3, 31)).pace.status
  end

  test "a personal-budgets family uses the viewer's own budget, not the household one" do
    @family.update!(personal_budgets: true)
    household = create_budget(budgeted: 1000)
    personal = create_budget(user: @user, budgeted: 2000)

    assert_equal personal, narrative.budget
    assert_not_equal household, narrative.budget
  end

  test "another family's budget is never used" do
    Budget.create!(family: families(:empty), start_date: Date.new(2024, 3, 1), end_date: Date.new(2024, 3, 31),
                   budgeted_spending: 1000, expected_income: 0, currency: "USD")

    assert_nil narrative.budget
  end

  # The page's three parts must count the same accounts. A member who does not
  # count an account in their finances sees none of its spending in the grid or
  # the movers, as they see none in the budget.
  test "the heatmap and the movers count only the viewer's accounts" do
    member = users(:family_member)
    private_account = Account.create!(family: @family, owner: @user, name: "Admin only", balance: 0, currency: "USD", accountable: Depository.new)
    assert_not_includes member.finance_accounts.pluck(:id), private_account.id
    category = @family.categories.create!(name: "Narrative private", color: "#101010", lucide_icon: "circle")
    create_transaction(account: private_account, category: category, amount: 400, date: Date.new(2024, 3, 5), name: "Private")

    as_owner = narrative(user: @user)
    as_member = narrative(user: member)

    assert_equal 400, as_owner.heatmap.total
    assert_equal [ 400 ], as_owner.top_movers.select { |m| m.category.id == category.id }.map { |m| m.delta.to_i }
    assert_equal 0, as_member.heatmap.total
    assert_empty as_member.top_movers.select { |m| m.category.id == category.id }
  end
end

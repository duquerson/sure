require "test_helper"

class HoldingsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  setup do
    sign_in users(:family_admin)
    @account = accounts(:investment)
    @holding = @account.holdings.first
  end

  test "gets holdings" do
    get holdings_url(account_id: @account.id)
    assert_response :success
  end

  test "gets holding" do
    get holding_path(@holding)

    assert_response :success
  end

  test "shows exact share count without rounding" do
    @holding.update!(qty: 10.374)

    get holding_path(@holding)

    assert_select "##{dom_id(@holding, :shares)}", text: "10.374"
  end

  test "shows the exact stored quantity for a small crypto holding in the holdings list" do
    account = accounts(:crypto)
    security = Security.create!(
      ticker: "CRYPTO:BTC",
      name: "Bitcoin",
      exchange_operating_mic: "XCBS",
      offline: true
    )
    holding = account.holdings.create!(
      security: security,
      date: Date.current,
      qty: BigDecimal("0.000000000000000148"),
      price: 100_000,
      amount: 14.884,
      currency: "USD"
    )

    get holdings_url(account_id: account.id)

    assert_select "##{dom_id(holding)} p", text: "0.000000000000000148 shares"
  end

  test "destroys holding and associated entries" do
    assert_difference -> { Holding.count } => -1,
                      -> { Entry.count } => -1 do
      delete holding_path(@holding)
    end

    assert_redirected_to account_path(@holding.account)
    assert_empty @holding.account.entries.where(entryable: @holding.account.trades.where(security: @holding.security))
  end

  test "updates cost basis with total amount divided by qty" do
    # Given: holding with 10 shares
    @holding.update!(qty: 10, cost_basis: nil, cost_basis_source: nil, cost_basis_locked: false)

    # When: user submits total cost basis of $100 (should become $10 per share)
    patch holding_path(@holding), params: { holding: { cost_basis: "100.00" } }

    # Redirects to account page holdings tab to refresh list
    assert_redirected_to account_path(@holding.account, tab: "holdings")
    @holding.reload

    # Then: cost_basis should be per-share ($10), not total
    assert_equal 10.0, @holding.cost_basis.to_f
    assert_equal "manual", @holding.cost_basis_source
    assert @holding.cost_basis_locked?
  end

  test "unlock_cost_basis removes lock" do
    # Given: locked holding
    @holding.update!(cost_basis: 50.0, cost_basis_source: "manual", cost_basis_locked: true)

    # When: user unlocks
    post unlock_cost_basis_holding_path(@holding)

    # Redirects to account page holdings tab to refresh list
    assert_redirected_to account_path(@holding.account, tab: "holdings")
    @holding.reload

    # Then: lock is removed but cost_basis and source remain
    assert_not @holding.cost_basis_locked?
    assert_equal 50.0, @holding.cost_basis.to_f
    assert_equal "manual", @holding.cost_basis_source
  end

  test "remap_security brings offline security back online" do
    # Given: the target security is marked offline (e.g. created by a failed QIF import)
    msft = securities(:msft)
    msft.update!(offline: true, failed_fetch_count: 3)

    # When: user explicitly selects it from the provider search and saves
    patch remap_security_holding_path(@holding), params: { security_id: "MSFT|XNAS" }

    # Then: the security is brought back online and the holding is remapped
    assert_redirected_to account_path(@holding.account, tab: "holdings")
    @holding.reload
    msft.reload
    assert_equal msft.id, @holding.security_id
    assert_not msft.offline?
    assert_equal 0, msft.failed_fetch_count
  end

  test "sync_prices redirects with alert for offline security" do
    @holding.security.update!(offline: true)

    post sync_prices_holding_path(@holding)

    assert_redirected_to account_path(@holding.account, tab: "holdings")
    assert_equal I18n.t("holdings.sync_prices.unavailable"), flash[:alert]
  end

  test "sync_prices syncs market data and redirects with notice" do
    Security.any_instance.expects(:import_provider_prices).with(
      start_date: 31.days.ago.to_date,
      end_date: Date.current,
      clear_cache: true
    ).returns([ 31, nil ])
    Security.any_instance.stubs(:import_provider_details)
    materializer = mock("materializer")
    materializer.expects(:materialize_balances).once
    Balance::Materializer.expects(:new).with(
      @holding.account,
      strategy: :forward,
      security_ids: [ @holding.security_id ]
    ).returns(materializer)

    post sync_prices_holding_path(@holding)

    assert_redirected_to account_path(@holding.account, tab: "holdings")
    assert_equal I18n.t("holdings.sync_prices.success"), flash[:notice]
  end

  test "sync_prices shows provider error inline when provider returns no prices" do
    Security.any_instance.stubs(:import_provider_prices).returns([ 0, "Yahoo Finance rate limit exceeded" ])
    Security.any_instance.stubs(:import_provider_details)

    post sync_prices_holding_path(@holding)

    assert_redirected_to account_path(@holding.account, tab: "holdings")
    assert_equal "Yahoo Finance rate limit exceeded", flash[:alert]
  end

  # #301 — a remap whose negative-amount row the old save!/update! rejected
  # must now succeed and reach the user as a success notice (not an error).
  test "remap_security on a negative-amount holding redirects with success notice" do
    # Force the holding into the materializer-produced negative state (upsert_all
    # bypasses the >=0 validation), which the old model code raised on.
    @holding.update_columns(qty: -22, amount: BigDecimal("-3187.80"))

    msft = securities(:msft)
    Balance::Materializer.any_instance.stubs(:materialize_balances)

    patch remap_security_holding_path(@holding), params: { security_id: "MSFT|XNAS" }

    assert_redirected_to account_path(@holding.account, tab: "holdings")
    assert_equal I18n.t("holdings.remap_security.success"), flash[:notice]
    assert_nil flash[:alert]
    @holding.reload
    assert_equal msft.id, @holding.security_id
    assert @holding.security_locked?
  end

  # #314 review (cubic, Gatekeeper): a failure after the remap has written must
  # undo the remap, so "Nothing was changed" is true. Re-materialising is made
  # to fail; the real remap runs before it, so this exercises the real writes.
  test "remap_security rolls the remap back when re-materialising fails" do
    old_security_id = @holding.security_id
    create_trade(@holding.security, account: @account, qty: 3, price: 10, date: Date.current)
    trades_before = @account.trades.where(security_id: old_security_id).count
    Balance::Materializer.any_instance.stubs(:materialize_balances).raises(StandardError, "forced test failure")

    assert_no_difference -> { Security.count } do
      patch remap_security_holding_path(@holding), params: { security_id: "NEWREMAP|XNAS" }
    end

    assert_redirected_to account_path(@holding.account, tab: "holdings")
    assert_equal I18n.t("holdings.remap_security.failed"), flash[:alert]
    assert_nil flash[:notice]
    assert_equal old_security_id, @holding.reload.security_id
    assert_not @holding.security_locked?
    assert_equal trades_before, @account.trades.where(security_id: old_security_id).count
  end

  # #301 triage review note 1: saving the chosen security can fail too (an
  # unknown price provider fails its inclusion check). That must also reach the
  # user as an alert, not an error response.
  test "remap_security with a security that cannot be saved shows an alert" do
    old_security_id = @holding.security_id

    assert_no_difference -> { Security.count } do
      patch remap_security_holding_path(@holding), params: { security_id: "NEWREMAP|XNAS|not_a_provider" }
    end

    assert_redirected_to account_path(@holding.account, tab: "holdings")
    assert_equal I18n.t("holdings.remap_security.failed"), flash[:alert]
    assert_equal old_security_id, @holding.reload.security_id
  end

  # #314 review (Gatekeeper): a failure inside the reset's own transaction,
  # after the trades have moved back, must undo that move and reach the user
  # as an alert. Only the holding write is made to fail.
  test "reset_security rolls the reset back when a holding write fails" do
    original = @holding.security
    remapped = securities(:msft)
    create_trade(original, account: @account, qty: 3, price: 10, date: Date.current)
    @holding.remap_security!(remapped)
    trades_on_remapped = @account.trades.where(security: remapped).count
    assert_operator trades_on_remapped, :>, 0

    Holding.any_instance.stubs(:update_columns).raises(ActiveRecord::StatementInvalid, "forced test failure")

    post reset_security_holding_path(@holding)

    assert_redirected_to account_path(@holding.account, tab: "holdings")
    assert_equal I18n.t("holdings.reset_security.failed"), flash[:alert]
    assert_nil flash[:notice]
    Holding.any_instance.unstub(:update_columns)
    assert_equal remapped.id, @holding.reload.security_id
    assert_equal trades_on_remapped, @account.trades.where(security: remapped).count
  end
end

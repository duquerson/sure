require "test_helper"

# Panel placement for issue #298: the sync button and the actions menu must
# render inside the card header row (the disclosure's <summary>), on par with
# the Wise card — not as a sibling row below it.
class CoinSpotItemPanelRenderTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    sign_in users(:family_admin)
    @item = coinspot_items(:one)
  end

  test "admin: sync and menu buttons render in the card header row" do
    get accounts_url
    assert_response :success
    assert_select "##{dom_id(@item)}", count: 1

    # The header row is the disclosure's <summary>; both actions are
    # button_to forms. A regression back to the old markup (buttons in a
    # sibling `mt-2` div outside the summary) fails exactly these two.
    assert_select "##{dom_id(@item)} details > summary form[action=?]", sync_coinspot_item_path(@item), count: 1
    assert_select "##{dom_id(@item)} details > summary form[action=?]", coinspot_item_path(@item), count: 1

    # No leftover duplicate actions row anywhere else in the card.
    assert_select "##{dom_id(@item)} form[action=?]", sync_coinspot_item_path(@item), count: 1
    assert_select "##{dom_id(@item)} form[action=?]", coinspot_item_path(@item), count: 1
  end

  test "admin: import accounts menu link sits in the header only while accounts are unlinked" do
    import_link = "##{dom_id(@item)} details > summary a[href=?]"

    # Without unlinked accounts the menu has no import link. The fixture's
    # coinspot_accounts(:one) is unlinked, so clear it first rather than
    # assume the precondition.
    @item.coinspot_accounts.destroy_all
    get accounts_url
    assert_response :success
    assert_select import_link, setup_accounts_coinspot_item_path(@item), count: 0

    CoinspotAccount.create!(
      coinspot_item: @item,
      name: "BTC Wallet",
      account_id: "cs-test-btc",
      account_type: "crypto",
      currency: "BTC"
    )

    get accounts_url
    assert_response :success
    assert_select import_link, setup_accounts_coinspot_item_path(@item), count: 1
  end

  test "sync button is disabled only while the item is syncing" do
    disabled_sync = "##{dom_id(@item)} details > summary form[action=?] button[disabled]"

    get accounts_url
    assert_response :success
    assert_select disabled_sync, sync_coinspot_item_path(@item), count: 0

    # The controller loads its own record, so stub every instance rather than
    # the test's @item.
    CoinspotItem.any_instance.stubs(:syncing?).returns(true)

    get accounts_url
    assert_response :success
    assert_select disabled_sync, sync_coinspot_item_path(@item), count: 1
  end

  test "non-admin: no sync or menu buttons on the card at all" do
    member = users(:family_member)
    # A member only sees a provider card holding an account they can access,
    # so link the fixture CoinSpot account to one the member owns. Without it
    # the card is absent and the count-0 assertions below would prove nothing.
    account = Account.create!(
      family: @item.family, owner: member, name: "Member CoinSpot",
      balance: 0, currency: "AUD", accountable: Crypto.new
    )
    assert coinspot_accounts(:one).ensure_account_provider!(account)
    sign_in member

    get accounts_url
    assert_response :success
    assert_select "##{dom_id(@item)}", count: 1
    assert_select "##{dom_id(@item)} form[action=?]", sync_coinspot_item_path(@item), count: 0
    assert_select "##{dom_id(@item)} form[action=?]", coinspot_item_path(@item), count: 0
  end
end

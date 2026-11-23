# frozen_string_literal: true

require "test_helper"

class OnchainWalletItemsControllerTest < ActionDispatch::IntegrationTest
  include OnchainTestHelper, BitcoinExplorerTestHelper

  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)
    register_fake_chain!
    @family = families(:dylan_family)
  end

  teardown do
    unregister_fake_chain!
  end

  test "new_wallet renders the address form with the read-only and Bitcoin notes" do
    get new_wallet_onchain_wallet_items_url

    assert_response :success
    assert_includes response.parsed_body.text, I18n.t("onchain_wallet_items.new_wallet.bitcoin_single_address_note")
    # "Can Sure spend my coins?" is asked while pasting an address, not while
    # reading a settings page for the third time.
    assert_match I18n.t("settings.providers.onchain_wallet_panel.keyless_title"), response.body
    assert_match I18n.t("onchain_wallet_items.new_wallet.read_only_note"), response.body
  end

  test "the settings panel renders before anything is linked" do
    get connect_form_settings_providers_path(provider_key: "onchain_wallet")

    assert_response :success
    assert_select "a[href=?]", new_wallet_onchain_wallet_items_path
  end

  test "the settings panel renders the tracked wallets and the connection settings" do
    item = create_onchain_wallet_item(family: @family)
    create_onchain_wallet_account(item: item)

    get connect_form_settings_providers_path(provider_key: "onchain_wallet")

    assert_response :success
    assert_match OnchainTestHelper::FAKE_ADDRESS.first(6), response.body
    assert_match I18n.t("settings.providers.onchain_wallet_panel.etherscan_api_key_label"), response.body
    assert_match I18n.t("settings.providers.onchain_wallet_panel.sync_start_date_label"), response.body
    assert_select "form[action=?]", sync_onchain_wallet_item_path(item)
    assert_select "a[href=?]", manage_onchain_wallet_item_path(item)
  end

  test "the price provider warning appears only when no crypto provider is enabled" do
    get new_wallet_onchain_wallet_items_url
    assert_match I18n.t("onchain_wallet_items.price_provider_warning.title"), response.body

    Setting.stubs(:enabled_securities_providers).returns([ Onchain::SecurityResolver::PRICE_PROVIDER ])

    get new_wallet_onchain_wallet_items_url
    assert_no_match I18n.t("onchain_wallet_items.price_provider_warning.title"), response.body
  end

  test "a non-USD family is warned that nothing can convert USD prices" do
    Setting.stubs(:enabled_securities_providers).returns([ Onchain::SecurityResolver::PRICE_PROVIDER ])
    ExchangeRate.stubs(:provider).returns(nil)
    @family.update!(currency: "EUR")

    get new_wallet_onchain_wallet_items_url

    assert_match I18n.t("onchain_wallet_items.price_provider_warning.exchange_rate_title"), response.body
    assert_no_match I18n.t("onchain_wallet_items.price_provider_warning.title"), response.body
  end

  test "a USD family with crypto prices on sees no pricing warning at all" do
    Setting.stubs(:enabled_securities_providers).returns([ Onchain::SecurityResolver::PRICE_PROVIDER ])

    get new_wallet_onchain_wallet_items_url

    assert_no_match I18n.t("onchain_wallet_items.price_provider_warning.title"), response.body
    assert_no_match I18n.t("onchain_wallet_items.price_provider_warning.exchange_rate_title"), response.body
  end

  test "the warning offers a one-click fix on a self-hosted instance" do
    Rails.configuration.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))

    get new_wallet_onchain_wallet_items_url

    assert_select "form[action=?]", enable_crypto_prices_onchain_wallet_items_path
  end

  # The one-click fix is a form of its own. Rendered inside the token review
  # form, it closed that form early and left "Track selected assets" submitting
  # nothing at all.
  test "the one-click fix does not swallow the token review form" do
    Rails.configuration.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))
    stub_wallet_with_token

    post preview_wallet_onchain_wallet_items_url, params: {
      address: OnchainTestHelper::FAKE_ADDRESS,
      chain: OnchainTestHelper::FAKE_CHAIN
    }

    assert_response :success
    assert_select "form[action=?]", enable_crypto_prices_onchain_wallet_items_path
    assert_select "form[action=?]", link_wallet_onchain_wallet_items_path do
      assert_select "input[name='assets[]']", 2
      assert_select "button[type=submit]", 1
    end
  end

  test "enable_crypto_prices adds the crypto provider without disabling the others" do
    Rails.configuration.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))
    Setting.securities_providers = "twelve_data"

    post enable_crypto_prices_onchain_wallet_items_url

    assert_response :redirect
    assert Onchain::SecurityResolver.price_provider_enabled?
    assert_includes Setting.enabled_securities_providers, "twelve_data"
  end

  test "enable_crypto_prices is refused on a managed instance where the operator decides" do
    Setting.securities_providers = "twelve_data"

    post enable_crypto_prices_onchain_wallet_items_url

    assert_response :redirect
    assert_not Onchain::SecurityResolver.price_provider_enabled?
    assert_equal I18n.t("onchain_wallet_items.enable_crypto_prices.not_self_hosted"), flash[:alert]
  end

  test "a member without admin rights is not offered the one-click fix" do
    Rails.configuration.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))
    sign_in users(:family_member)

    get manage_onchain_wallet_item_url(create_onchain_wallet_item(family: @family))

    assert_response :redirect
  end

  test "preview_wallet reads the assets and none of the transfer history" do
    snapshot = Onchain::Snapshot.new(assets: [ fake_native_asset(quantity: 2) ], movements: [])
    OnchainTestHelper::FakeAdapter.any_instance.expects(:fetch_assets).with(OnchainTestHelper::FAKE_ADDRESS).returns(snapshot)
    OnchainTestHelper::FakeAdapter.any_instance.expects(:fetch_snapshot).never

    post preview_wallet_onchain_wallet_items_url, params: { address: OnchainTestHelper::FAKE_ADDRESS }

    assert_response :success
    assert_select "input[name='assets[]'][value='native']"
  end

  test "preview_wallet lists what the address holds, pre-checking only vouched-for assets" do
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(
        assets: [
          fake_native_asset(quantity: 2),
          fake_token_asset(symbol: "USDC", contract: "0xusdc", quantity: 10),
          fake_token_asset(symbol: "Visit site to claim", contract: "0xspam", quantity: 1),
          # An airdrop with a perfectly plausible symbol: only the data source's
          # own signal separates it from the real thing.
          fake_token_asset(symbol: "0XBTC", contract: "0xairdrop", quantity: 1, notable: false)
        ],
        movements: []
      )
    )

    post preview_wallet_onchain_wallet_items_url, params: { address: OnchainTestHelper::FAKE_ADDRESS }

    assert_response :success
    assert_match "USDC", response.body
    assert_match I18n.t("onchain_wallet_items.token_review_form.no_price"), response.body
    assert_select "input[name='assets[]'][value='native'][checked]"
    assert_select "input[name='assets[]'][value='erc20:0xusdc'][checked]"
    assert_select "input[name='assets[]'][value='erc20:0xspam']"
    assert_select "input[name='assets[]'][value='erc20:0xspam'][checked]", false
    assert_select "input[name='assets[]'][value='erc20:0xairdrop']"
    assert_select "input[name='assets[]'][value='erc20:0xairdrop'][checked]", false
  end

  test "preview_wallet rejects an address that belongs to no supported chain" do
    post preview_wallet_onchain_wallet_items_url, params: { address: "definitely-not-an-address" }

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.unrecognized_address"), response.body
  end

  test "preview_wallet asks which chain when several report activity" do
    other = "otherchain"
    Onchain::Chains.register(
      Onchain::Chains::Definition.new(
        key: other,
        native: Onchain::Chains::NativeAsset.new(symbol: "OTHER", name: "Other", decimals: 8),
        token_kind: nil,
        adapter_class_name: "OnchainTestHelper::FakeAdapter",
        adapter_options: {}
      )
    )

    post preview_wallet_onchain_wallet_items_url, params: { address: OnchainTestHelper::FAKE_ADDRESS }

    assert_response :success
    assert_match I18n.t("onchain_wallet_items.choose_chain.title"), response.body
    assert_match I18n.t("onchain_wallet_items.choose_chain.activity_found"), response.body
  ensure
    Onchain::Chains.unregister(other)
  end

  test "an expected explorer failure surfaces as a localized message" do
    OnchainTestHelper::FakeAdapter.error = Onchain::Chains::UnreachableError.new("blockscout down")

    post preview_wallet_onchain_wallet_items_url, params: { address: OnchainTestHelper::FAKE_ADDRESS }

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.chain_unreachable"), response.body
    assert_no_match "blockscout down", response.body
  end

  test "a data source that times out reads as unreachable, not as our own failure" do
    OnchainTestHelper::FakeAdapter.error = Provider::MempoolSpace::ApiError.new("MempoolSpace is unavailable (Net::ReadTimeout)")
    OnchainTestHelper::FakeAdapter.provider_error_classes = [ Provider::MempoolSpace::RateLimitError, Provider::MempoolSpace::Error ]

    assert_no_difference "DebugLogEntry.count" do
      post preview_wallet_onchain_wallet_items_url, params: { address: OnchainTestHelper::FAKE_ADDRESS }
    end

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.chain_unreachable"), response.body
    assert_no_match "Net::ReadTimeout", response.body
  end

  test "an unexpected failure is recorded and never interpolated into the response" do
    OnchainTestHelper::FakeAdapter.error = NoMethodError.new("undefined method 'boom' for nil")

    assert_difference "DebugLogEntry.count", 1 do
      post preview_wallet_onchain_wallet_items_url, params: { address: OnchainTestHelper::FAKE_ADDRESS }
    end

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.unexpected"), response.body
    assert_no_match "undefined method", response.body
    assert_equal "onchain_wallet", DebugLogEntry.order(:created_at).last.provider_key
  end

  test "link_wallet tracks only the ticked assets and creates one account each" do
    stub_wallet_with_token

    assert_difference [ "OnchainWalletAccount.count", "Account.count" ], 1 do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS,
        assets: [ "native" ]
      }
    end

    assert_redirected_to accounts_path
    onchain_account = OnchainWalletAccount.order(:created_at).last
    assert_equal "native", onchain_account.asset_kind
    assert_equal @family, onchain_account.onchain_wallet_item.family
    assert_equal "Crypto", onchain_account.account.accountable_type
    assert_equal "wallet", onchain_account.account.accountable.subtype
  end

  test "link_wallet ignores an asset the chain does not report" do
    stub_wallet_with_token

    assert_difference "OnchainWalletAccount.count", 1 do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS,
        assets: [ "native", "erc20:0xnothere" ]
      }
    end
  end

  test "link_wallet refuses an address the family already tracks" do
    item = create_onchain_wallet_item(family: @family)
    link_onchain_wallet_account!(create_onchain_wallet_account(item: item))
    stub_wallet_with_token

    assert_no_difference "OnchainWalletAccount.count" do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS,
        assets: [ "native" ]
      }
    end

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.already_linked"), response.body
  end

  test "preview_wallet refuses an address the family already tracks" do
    item = create_onchain_wallet_item(family: @family)
    link_onchain_wallet_account!(create_onchain_wallet_account(item: item))

    post preview_wallet_onchain_wallet_items_url, params: {
      address: OnchainTestHelper::FAKE_ADDRESS,
      chain: OnchainTestHelper::FAKE_CHAIN
    }

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.already_linked"), response.body
  end

  test "a failed read leaves no empty connection behind" do
    OnchainTestHelper::FakeAdapter.error = Onchain::Chains::UnreachableError.new("explorer down")

    assert_no_difference "OnchainWalletItem.count" do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS,
        assets: [ "native" ]
      }
    end

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.chain_unreachable"), response.body
  end

  test "assets that were ticked but could not be tracked are named, not blamed on the user" do
    stub_wallet_with_token
    OnchainWalletItem::WalletLinker.any_instance.stubs(:link).returns(
      OnchainWalletItem::WalletLinker::Result.new(created: 0, removed: 0, errors: [ "USDC" ])
    )

    post link_wallet_onchain_wallet_items_url, params: {
      chain: OnchainTestHelper::FAKE_CHAIN,
      address: OnchainTestHelper::FAKE_ADDRESS,
      assets: [ "erc20:0xusdc" ]
    }

    assert_response :unprocessable_entity
    assert_match "USDC", response.body
    # Being told to "pick at least one asset" would send them back to tick the
    # same one.
    assert_no_match I18n.t("onchain_wallet_items.link_wallet.errors.nothing_selected"), response.body
  end

  test "a partial failure is reported alongside what did get tracked" do
    stub_wallet_with_token
    OnchainWalletItem::WalletLinker.any_instance.stubs(:link).returns(
      OnchainWalletItem::WalletLinker::Result.new(created: 1, removed: 0, errors: [ "USDC" ])
    )

    post link_wallet_onchain_wallet_items_url, params: {
      chain: OnchainTestHelper::FAKE_CHAIN,
      address: OnchainTestHelper::FAKE_ADDRESS,
      assets: [ "native", "erc20:0xusdc" ]
    }

    assert_redirected_to accounts_path
    assert_match "USDC", flash[:alert]
  end

  test "the settings link is not offered to anyone who cannot open that page" do
    # Managed instance: market data is the operator's setting and the page is
    # gated, so a link there is a dead end. Asserted on the link's own text —
    # the settings layout mentions that path for its own reasons.
    link = I18n.t("onchain_wallet_items.price_provider_warning.link")

    get new_wallet_onchain_wallet_items_url
    assert_match I18n.t("onchain_wallet_items.price_provider_warning.title"), response.body
    assert_no_match link, response.body

    Rails.configuration.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))
    get new_wallet_onchain_wallet_items_url
    assert_match link, response.body

    sign_in users(:family_member)
    get manage_onchain_wallet_item_url(create_onchain_wallet_item(family: @family))
    assert_response :redirect
  end

  test "link_wallet with nothing ticked reopens the selection" do
    stub_wallet_with_token

    assert_no_difference "OnchainWalletAccount.count" do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS
      }
    end

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.link_wallet.errors.nothing_selected"), response.body
  end

  test "previewing an address never leaves an empty connection behind" do
    stub_wallet_with_token

    assert_no_difference "OnchainWalletItem.count" do
      post preview_wallet_onchain_wallet_items_url, params: { address: OnchainTestHelper::FAKE_ADDRESS }
    end
  end

  test "sync schedules a sync for the family's own connection only" do
    item = create_onchain_wallet_item(family: @family)
    other_family_item = create_onchain_wallet_item(family: families(:empty))

    post sync_onchain_wallet_item_url(item)
    assert_redirected_to settings_providers_path

    post sync_onchain_wallet_item_url(other_family_item)
    assert_response :not_found
  end

  test "destroy schedules the connection for deletion" do
    item = create_onchain_wallet_item(family: @family)

    delete onchain_wallet_item_url(item)

    assert_redirected_to settings_providers_path
    assert item.reload.scheduled_for_deletion
  end

  test "update stores an explorer key and keeps it when the field is left blank" do
    item = create_onchain_wallet_item(family: @family)

    patch onchain_wallet_item_url(item), params: { onchain_wallet_item: { etherscan_api_key: "abc123" } }
    assert_equal "abc123", item.reload.etherscan_api_key

    patch onchain_wallet_item_url(item), params: { onchain_wallet_item: { etherscan_api_key: "" } }
    assert_equal "abc123", item.reload.etherscan_api_key
  end

  test "update stores the date before which transfers are ignored" do
    item = create_onchain_wallet_item(family: @family)

    patch onchain_wallet_item_url(item), params: { onchain_wallet_item: { sync_start_date: "2026-01-15" } }

    assert_equal Date.new(2026, 1, 15), item.reload.sync_start_date.to_date
  end

  # Redirecting back to Bank sync collapses the open connection row. The panel
  # root carries the id, so it is replaced rather than nested inside itself.
  test "update from the page re-renders the panel in place" do
    item = create_onchain_wallet_item(family: @family)

    patch onchain_wallet_item_url(item),
          params: { onchain_wallet_item: { sync_start_date: "2026-01-15" } },
          as: :turbo_stream

    assert_turbo_stream action: "replace", target: "onchain_wallet-providers-panel"
    assert_includes response.body, %(id="onchain_wallet-providers-panel")
    assert_equal Date.new(2026, 1, 15), item.reload.sync_start_date.to_date
  end

  test "linking creates the single connection every wallet hangs off" do
    stub_wallet_with_token
    stub_wallet_with_token(address: OnchainTestHelper::FAKE_ADDRESS_ALT)

    assert_difference "OnchainWalletItem.count", 1 do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS,
        assets: [ "native" ]
      }
    end

    assert_no_difference "OnchainWalletItem.count" do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS_ALT,
        assets: [ "native" ]
      }
    end

    assert_equal 2, @family.reload.onchain_wallet_items.sole.wallet_keys.size
  end

  test "a member without admin rights cannot link a wallet" do
    sign_in users(:family_member)

    get new_wallet_onchain_wallet_items_url

    assert_response :redirect
  end

  test "manage lists every tracked address and offers its actions" do
    item = create_onchain_wallet_item(family: @family)
    native = create_onchain_wallet_account(item: item)
    token_asset = create_onchain_wallet_account(item: item, asset: fake_token_asset(symbol: "USDC", contract: "0xusdc"))

    get manage_onchain_wallet_item_url(item)

    assert_response :success
    assert_match OnchainTestHelper::FAKE_ADDRESS, response.body
    assert_match I18n.t("onchain_wallet_items.manage.review_tokens"), response.body
    assert_match I18n.t("onchain_wallet_items.manage.disconnect_wallet"), response.body
    # Per-asset action, for each asset, not just one for the wallet.
    assert_select "form[action=?]", disconnect_asset_onchain_wallet_item_path(item), count: 2
    # The per-address actions live in a menu, as the accounts page renders its
    # own repeated row actions.
    assert_select "form[action=?]", disconnect_wallet_onchain_wallet_item_path(item), count: 1
    assert_match native.symbol, response.body
    assert_match token_asset.symbol, response.body
  end

  test "review_tokens reopens the selection with the address unchanged" do
    item = create_onchain_wallet_item(family: @family)
    create_onchain_wallet_account(item: item)
    stub_wallet_with_token

    get review_tokens_onchain_wallet_item_url(item, chain: OnchainTestHelper::FAKE_CHAIN, address: OnchainTestHelper::FAKE_ADDRESS)

    assert_response :success
    assert_select "input[name=address][value=?]", OnchainTestHelper::FAKE_ADDRESS
    assert_select "input[name='new_address']", false
    assert_select "input[name='assets[]'][value='native'][checked]"
    assert_select "input[name='assets[]'][value='erc20:0xusdc'][checked]"
  end

  test "update_tokens adds a newly ticked asset and stops tracking an unticked one" do
    item = create_onchain_wallet_item(family: @family)
    native = create_onchain_wallet_account(item: item)
    stub_wallet_with_token

    assert_difference "OnchainWalletAccount.count", 0 do
      post update_tokens_onchain_wallet_item_url(item), params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS,
        assets: [ "erc20:0xusdc" ]
      }
    end

    assert_redirected_to manage_onchain_wallet_item_path(item)
    assert_not OnchainWalletAccount.exists?(native.id)
    assert_equal [ "USDC" ], item.reload.onchain_wallet_accounts.pluck(:symbol)
  end

  test "unticking one asset removes only it" do
    item = create_onchain_wallet_item(family: @family)
    # Linked, because that is what a tracked asset actually is. Left unlinked
    # these are orphan rows, and revising now rebuilds those into real ones —
    # so the surviving row would be a new one and the assertion below would be
    # measuring the repair rather than the removal.
    native = create_onchain_wallet_account(item: item)
    link_onchain_wallet_account!(native)
    token_asset = create_onchain_wallet_account(item: item, asset: fake_token_asset(symbol: "USDC", contract: "0xusdc"))
    link_onchain_wallet_account!(token_asset)
    stub_wallet_with_token

    post update_tokens_onchain_wallet_item_url(item), params: {
      chain: OnchainTestHelper::FAKE_CHAIN,
      address: OnchainTestHelper::FAKE_ADDRESS,
      assets: [ "native" ]
    }

    assert OnchainWalletAccount.exists?(native.id)
    assert_not OnchainWalletAccount.exists?(token_asset.id)
  end

  test "an asset the chain no longer reports can still be unticked" do
    item = create_onchain_wallet_item(family: @family)
    gone = create_onchain_wallet_account(item: item, asset: fake_token_asset(symbol: "GONE", contract: "0xgone"))
    create_onchain_wallet_account(item: item)
    stub_wallet_with_token

    get review_tokens_onchain_wallet_item_url(item, chain: OnchainTestHelper::FAKE_CHAIN, address: OnchainTestHelper::FAKE_ADDRESS)
    assert_select "input[name='assets[]'][value='erc20:0xgone'][checked]"

    post update_tokens_onchain_wallet_item_url(item), params: {
      chain: OnchainTestHelper::FAKE_CHAIN,
      address: OnchainTestHelper::FAKE_ADDRESS,
      assets: [ "native" ]
    }

    assert_not OnchainWalletAccount.exists?(gone.id)
  end

  test "disconnect_wallet stops tracking every asset at that address only" do
    item = create_onchain_wallet_item(family: @family)
    create_onchain_wallet_account(item: item)
    create_onchain_wallet_account(item: item, asset: fake_token_asset(contract: "0xusdc"))
    kept = create_onchain_wallet_account(item: item, address: OnchainTestHelper::FAKE_ADDRESS_ALT)

    assert_difference "OnchainWalletAccount.count", -2 do
      delete disconnect_wallet_onchain_wallet_item_url(item), params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS
      }
    end

    assert OnchainWalletAccount.exists?(kept.id)
  end

  test "disconnecting keeps the account and its holdings as a manual account" do
    item = create_onchain_wallet_item(family: @family)
    onchain_account = create_onchain_wallet_account(item: item)
    account = link_onchain_wallet_account!(onchain_account)
    security = Onchain::SecurityResolver.resolve(symbol: onchain_account.symbol)
    holding = account.holdings.create!(
      security: security, date: Date.current, qty: 1, price: 1, amount: 1,
      currency: account.currency, account_provider_id: onchain_account.account_provider.id
    )

    delete disconnect_asset_onchain_wallet_item_url(item), params: { onchain_wallet_account_id: onchain_account.id }

    assert Account.exists?(account.id)
    assert holding.reload.persisted?
    assert_nil holding.account_provider_id
    assert_not AccountProvider.exists?(provider_type: "OnchainWalletAccount", provider_id: onchain_account.id)
  end

  test "management actions refuse a wallet this connection does not track" do
    item = create_onchain_wallet_item(family: @family)
    create_onchain_wallet_account(item: item)

    get review_tokens_onchain_wallet_item_url(item, chain: OnchainTestHelper::FAKE_CHAIN, address: OnchainTestHelper::FAKE_ADDRESS_ALT)

    assert_redirected_to manage_onchain_wallet_item_path(item)
    assert_equal I18n.t("onchain_wallet_items.errors.wallet_not_found"), flash[:alert]
  end

  test "management actions cannot reach another family's connection" do
    other_family_item = create_onchain_wallet_item(family: families(:empty))
    create_onchain_wallet_account(item: other_family_item)

    get manage_onchain_wallet_item_url(other_family_item)
    assert_response :not_found

    delete disconnect_wallet_onchain_wallet_item_url(other_family_item), params: {
      chain: OnchainTestHelper::FAKE_CHAIN,
      address: OnchainTestHelper::FAKE_ADDRESS
    }
    assert_response :not_found
    assert_equal 1, other_family_item.onchain_wallet_accounts.count
  end

  test "disconnect_asset cannot reach a row belonging to another connection" do
    item = create_onchain_wallet_item(family: @family)
    other_item = create_onchain_wallet_item(family: families(:empty))
    other_account = create_onchain_wallet_account(item: other_item)

    delete disconnect_asset_onchain_wallet_item_url(item), params: { onchain_wallet_account_id: other_account.id }

    assert_response :not_found
    assert OnchainWalletAccount.exists?(other_account.id)
  end

  # --- Wallets followed by an account key. Nothing below stubs an explorer unless
  # it says so: WebMock fails the test on any request the flow would make. ---

  test "a ypub or zpub states its script type and goes straight to the review" do
    preview_bitcoin(BIP84_ZPUB)

    assert_response :success
    assert_select "form[action=?]", link_wallet_onchain_wallet_items_path do
      assert_select "input[name=address][value=?]", BIP84_ZPUB
      assert_select "input[name=script_type][value=p2wpkh]"
      assert_select "input[name='assets[]'][value=native][checked]"
    end
    # The owner recognizes the account by the address the wallet shows first.
    assert_match bitcoin_account.first_address, response.body
    assert_match I18n.t("onchain_wallet_items.token_review_form.quantity_after_sync"), response.body
  end

  test "an xpub asks for its script type, showing each one's first address" do
    preview_bitcoin(BIP84_XPUB)

    assert_response :success
    assert_select "form[action=?]", preview_wallet_onchain_wallet_items_path do
      assert_select "input[name=address][value=?]", BIP84_XPUB
      assert_select "input[name=script_type]", 4
      # Nothing is chosen on the owner's behalf.
      assert_select "input[name=script_type][checked]", false
      assert_select "input[name=known_address]"
    end
    %w[p2pkh p2sh_p2wpkh p2wpkh p2tr].each do |script_type|
      assert_match bitcoin_account(script_type).first_address, response.body
    end
  end

  test "choosing the script type settles it" do
    preview_bitcoin(BIP84_XPUB, script_type: "p2tr")

    assert_response :success
    assert_select "input[name=script_type][value=p2tr]"
    assert_match bitcoin_account("p2tr").first_address, response.body
  end

  test "an address of the wallet settles the script type, receive or change" do
    [ bitcoin_account("p2sh_p2wpkh").address(0, 7), bitcoin_account("p2sh_p2wpkh").address(1, 2) ].each do |known_address|
      preview_bitcoin(BIP84_XPUB, known_address: known_address)

      assert_response :success
      assert_select "form[action=?] input[name=script_type][value=p2sh_p2wpkh]", link_wallet_onchain_wallet_items_path
    end
  end

  test "an address the key does not derive settles nothing" do
    preview_bitcoin(BIP84_XPUB, known_address: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq")

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.choose_script_type.errors.known_address_mismatch"), response.body
    assert_select "form[action=?]", link_wallet_onchain_wallet_items_path, false
    assert_select "input[name=script_type][checked]", false
  end

  test "a known address that contradicts the chosen script type is not overruled by it" do
    preview_bitcoin(BIP84_XPUB, script_type: "p2tr", known_address: bitcoin_account("p2wpkh").first_address)

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.choose_script_type.errors.known_address_mismatch"), response.body
  end

  test "a script type the key cannot have is not taken" do
    preview_bitcoin(BIP84_ZPUB, script_type: "p2tr")
    assert_response :unprocessable_entity

    preview_bitcoin(BIP84_XPUB, script_type: "nonsense")
    assert_response :unprocessable_entity
    assert_select "input[name=script_type]", 4
  end

  test "an xpub is never linked without a script type" do
    assert_no_difference [ "OnchainWalletAccount.count", "Account.count", "OnchainWalletItem.count" ] do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: Onchain::Chains::BITCOIN, address: BIP84_XPUB, assets: [ "native" ]
      }
    end

    assert_response :unprocessable_entity
    assert_select "input[name=script_type]", 4
  end

  test "linking an account key tracks one Bitcoin account and reads it in the background" do
    SyncJob.expects(:perform_later).at_least_once

    assert_difference [ "OnchainWalletAccount.count", "Account.count" ], 1 do
      link_bitcoin(BIP84_XPUB, script_type: "p2wpkh")
    end

    assert_redirected_to accounts_path
    row = OnchainWalletAccount.order(:created_at).last
    assert_equal BIP84_XPUB, row.extended_public_key
    assert_equal "p2wpkh", row.script_type
    assert_equal bitcoin_account.reference, row.wallet_address
  end

  test "the chain may be named or left to detection, but another chain refuses the key" do
    post preview_wallet_onchain_wallet_items_url, params: { address: BIP84_ZPUB, chain: Onchain::Chains::BITCOIN }
    assert_response :success

    post preview_wallet_onchain_wallet_items_url, params: { address: BIP84_ZPUB, chain: Onchain::Chains::ETHEREUM }
    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.unrecognized_address"), response.body
  end

  test "a secret is refused everywhere, unstored, unlogged and unechoed" do
    log = StringIO.new
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(log))
    Rails.stubs(:logger).returns(logger)
    ActionController::Base.stubs(:logger).returns(logger)

    # Published keys and phrases. The phrases are told apart from the page around
    # them by their words, so none may be ones the interface uses.
    phrase = %w[letter advice cage absurd amount doctor acoustic avoid letter advice cage bless]
    secrets = [
      BIP84_ZPRV,
      "xprv9xpXFhFpqdQK3TmytPBqXtGSwS3DLjojFhTGht8gwAAii8py5X6pxeBnQ6ehJiyJ6nDjWGJfZ95WxByFXVkDxHXrqu53WCRGypk2ttuqncb",
      "yprvAHwhK6RbpuS3dgCYHM5jc2ZvEKd7Bi61u9FVhYMpgMSuZS613T1xxQeKTffhrHY79hZ5PsskBjcc6C2V7DrnsMsNaGDaWev3GLRQRgV7hxF",
      "tprv8fVU32aAEuEPeH1WYx3LhXtSFZTRaFqjbFNPaJZ9R8fCVja44tSaUPZEKGpMK6McUDkWWMvRiVfKR3Wzei6AmLoTNYHMAZ9KtvVTLZZdhvA",
      "5HpHagT65TZzG1PH3CSu63k8DbpvD8s5ip4nEB3kEsreAnchuDf",
      "KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn",
      "91avARGdfge8E4tZfYLoxeJ5sGBdNJQH4kvjJoQFacbgwmaKkrx",
      "cMahea7zqjxrtgAbB7LSGbcQUr1uX1ojuat9jZodMN87JcbXMTcA",
      "0x#{"4c" * 32}",
      "2Ana1pUpv2ZbMVkwF5FXapYeBEjdxDatLn7nvJkhgTSXbs59SyZSx866bXirPgj8QQVB57uxHJBG1YFvkRbFj4T",
      *[ 12, 15, 18, 21, 24 ].map { |count| phrase.cycle.first(count).join(" ") },
      phrase.join(" ").upcase,
      phrase.join(", ")
    ]

    assert_no_difference [ "OnchainWalletAccount.count", "Account.count", "OnchainWalletItem.count", "DebugLogEntry.count" ] do
      secrets.each do |secret|
        [
          [ preview_wallet_onchain_wallet_items_url, { address: secret } ],
          [ preview_wallet_onchain_wallet_items_url, { address: " #{secret} ", chain: Onchain::Chains::BITCOIN } ],
          [ preview_wallet_onchain_wallet_items_url, { address: secret, chain: Onchain::Chains::ETHEREUM } ],
          [ preview_wallet_onchain_wallet_items_url, { address: [ secret ] } ],
          [ preview_wallet_onchain_wallet_items_url, { address: BIP84_XPUB, known_address: secret } ],
          [ link_wallet_onchain_wallet_items_url, { address: secret, chain: Onchain::Chains::BITCOIN, script_type: "p2wpkh", assets: [ "native" ] } ]
        ].each do |url, params|
          post url, params: params

          assert_response :unprocessable_entity
          assert_includes response.parsed_body.text, I18n.t("onchain_wallet_items.errors.private_key")
          assert_select "input[name=address]:not([value])", 1
          assert_not_includes response.body, secret
          assert_not_includes response.body, "acoustic"
        end
      end
    end

    secrets.each { |secret| assert_not_includes log.string, secret }
    assert_no_match(/acoustic/i, log.string)
  end

  test "a mistyped address is given back to be corrected" do
    preview_bitcoin("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdx")

    assert_response :unprocessable_entity
    assert_select "input[name=address][value=?]", "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdx"
  end

  # The browser must neither remember what is pasted here nor send it to a
  # spelling service.
  test "the fields an address is pasted into are kept from the browser's own services" do
    get new_wallet_onchain_wallet_items_url
    assert_select "input[name=address][autocomplete=off][spellcheck=false][autocapitalize=none]", 1

    preview_bitcoin(BIP84_XPUB)
    assert_select "input[name=known_address][autocomplete=off][spellcheck=false][autocapitalize=none]", 1
  end

  test "a key that is not a mainnet account key is named as the problem" do
    [
      "tpubD6NzVbkrYhZ4XgiXtGrdW5XDAPFCL9h7we1vwNCpn8tGbBcgfVYjXyhWo4E1xkh56hjod1RhGjxbaTLV3X4FyWuejifB9jusQ46QzG87VKp",
      "xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8",
      BIP84_ZPUB.chop + "a"
    ].each do |key|
      preview_bitcoin(key)

      assert_response :unprocessable_entity
      assert_match I18n.t("onchain_wallet_items.errors.invalid_account_key"), response.body
    end
  end

  test "an account already tracked is refused under any spelling of its key" do
    link_onchain_wallet_account!(create_bitcoin_account_row(item: create_onchain_wallet_item(family: @family)))

    preview_bitcoin(BIP84_ZPUB)
    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.already_linked"), response.body

    assert_no_difference("OnchainWalletAccount.count") { link_bitcoin(BIP84_ZPUB, script_type: "p2wpkh") }
    assert_response :unprocessable_entity

    preview_bitcoin(BIP84_XPUB, script_type: "p2tr")
    assert_response :success
  end

  test "an account containing an address tracked on its own is refused, naming the address" do
    address = bitcoin_account.address(0, 4)
    link_onchain_wallet_account!(
      create_onchain_wallet_account(
        item: create_onchain_wallet_item(family: @family),
        asset: Onchain::Chains.find!(Onchain::Chains::BITCOIN).native_asset(quantity: 1),
        chain: Onchain::Chains::BITCOIN, address: address
      )
    )

    preview_bitcoin(BIP84_ZPUB)
    assert_response :unprocessable_entity
    assert_match address, response.body

    assert_no_difference("OnchainWalletAccount.count") { link_bitcoin(BIP84_ZPUB, script_type: "p2wpkh") }
    assert_response :unprocessable_entity
  end

  test "an address inside a tracked account is refused" do
    link_onchain_wallet_account!(create_bitcoin_account_row(item: create_onchain_wallet_item(family: @family)))

    assert_no_difference "OnchainWalletAccount.count" do
      post preview_wallet_onchain_wallet_items_url, params: { address: bitcoin_account.address(1, 4), chain: Onchain::Chains::BITCOIN }
      assert_response :unprocessable_entity
      assert_match I18n.t("onchain_wallet_items.errors.address_in_tracked_account"), response.body

      post link_wallet_onchain_wallet_items_url, params: { address: bitcoin_account.address(1, 4), chain: Onchain::Chains::BITCOIN, assets: [ "native" ] }
      assert_response :unprocessable_entity
    end
  end

  test "a tracked account is managed by its reference, never by its key" do
    item = create_onchain_wallet_item(family: @family)
    row = create_bitcoin_account_row(item: item, quantity: BigDecimal("0.5"), extra: { "onchain_wallet" => { "history_truncated" => true, "addresses_truncated" => true } })
    link_onchain_wallet_account!(row)

    get manage_onchain_wallet_item_url(item)
    assert_response :success
    assert_match row.wallet_address, response.body
    assert_match ERB::Util.html_escape(I18n.t("onchain.script_types.p2wpkh")), response.body
    # "Balances are complete" would not be true of it.
    assert_match I18n.t("onchain_wallet_items.manage.addresses_truncated"), response.body
    assert_no_match I18n.t("onchain_wallet_items.manage.history_truncated"), response.body
    assert_not_includes response.body, BIP84_XPUB

    get review_tokens_onchain_wallet_item_url(item, chain: Onchain::Chains::BITCOIN, address: row.wallet_address)
    assert_response :success
    assert_match "0.5", response.body
    # What tells a wrong script type from an empty wallet after the fact.
    assert_match row.key_account.first_address, response.body
    assert_not_includes response.body, BIP84_XPUB
  end

  test "reviewing a tracked account leaves it or stops it" do
    item = create_onchain_wallet_item(family: @family)
    row = create_bitcoin_account_row(item: item)
    link_onchain_wallet_account!(row)
    wallet = { chain: Onchain::Chains::BITCOIN, address: row.wallet_address }

    post update_tokens_onchain_wallet_item_url(item), params: wallet.merge(assets: [ "native" ])
    assert_response :unprocessable_entity
    assert OnchainWalletAccount.exists?(row.id)

    post update_tokens_onchain_wallet_item_url(item), params: wallet
    assert_redirected_to manage_onchain_wallet_item_path(item)
    assert_not OnchainWalletAccount.exists?(row.id)
  end

  private
    def preview_bitcoin(key, **params)
      post preview_wallet_onchain_wallet_items_url, params: { address: key, **params }
    end

    def link_bitcoin(key, script_type:)
      post link_wallet_onchain_wallet_items_url, params: {
        chain: Onchain::Chains::BITCOIN, address: key, script_type: script_type, assets: [ "native" ]
      }
    end

    def stub_wallet_with_token(address: OnchainTestHelper::FAKE_ADDRESS)
      stub_fake_snapshot(
        address,
        Onchain::Snapshot.new(
          assets: [ fake_native_asset(quantity: 2), fake_token_asset(symbol: "USDC", contract: "0xusdc", quantity: 10) ],
          movements: []
        )
      )
    end
end

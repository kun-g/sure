# frozen_string_literal: true

require "test_helper"

class OnchainWalletAccountTest < ActiveSupport::TestCase
  include OnchainTestHelper, BitcoinExplorerTestHelper

  setup do
    register_fake_chain!
    @family = families(:dylan_family)
    @item = create_onchain_wallet_item(family: @family)
  end

  teardown do
    unregister_fake_chain!
  end

  test "an extended public key is stored encrypted and never shown by inspect" do
    row = create_bitcoin_account_row(item: @item)

    stored = OnchainWalletAccount.connection.select_value(
      "SELECT extended_public_key FROM onchain_wallet_accounts WHERE id = #{OnchainWalletAccount.connection.quote(row.id)}"
    )

    assert_not_includes stored, BIP84_XPUB
    assert_not_includes row.reload.inspect, BIP84_XPUB
    assert_equal BIP84_XPUB, row.extended_public_key
  end

  test "a row with a key stands for the account it was linked as" do
    row = create_bitcoin_account_row(item: @item, account: bitcoin_account("p2tr"))

    assert row.key_account?
    assert_equal bitcoin_account("p2tr").reference, row.reload.key_account.reference
    assert_not_includes row.display_name, BIP84_XPUB
    assert_not create_onchain_wallet_account(item: @item).key_account?
    assert_nil create_onchain_wallet_account(item: @item, address: OnchainTestHelper::FAKE_ADDRESS_ALT).key_account
  end

  test "a key without a script type, or a script type without a key, is refused" do
    row = create_bitcoin_account_row(item: @item)

    assert_not row.tap { |r| r.script_type = nil }.valid?
    assert_not row.reload.tap { |r| r.extended_public_key = nil }.valid?
    assert_raises(ActiveRecord::StatementInvalid) do
      OnchainWalletAccount.transaction(requires_new: true) { row.reload.update_column(:script_type, nil) }
    end
  end

  test "the database rejects a second native row for the same address" do
    create_onchain_wallet_account(item: @item)

    duplicate = @item.onchain_wallet_accounts.new(
      chain: OnchainTestHelper::FAKE_CHAIN,
      wallet_address: OnchainTestHelper::FAKE_ADDRESS,
      asset_kind: "native",
      symbol: "FAKE",
      decimals: 8,
      quantity: 3,
      currency: "USD"
    )

    # save(validate: false) proves the guarantee comes from the partial unique
    # index and not from the ActiveRecord validation above it.
    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test "the database rejects a second token row for the same contract" do
    create_onchain_wallet_account(item: @item, asset: fake_token_asset(contract: "0xAAA"))

    duplicate = @item.onchain_wallet_accounts.new(
      chain: OnchainTestHelper::FAKE_CHAIN,
      wallet_address: OnchainTestHelper::FAKE_ADDRESS,
      asset_kind: OnchainTestHelper::FAKE_TOKEN_KIND,
      contract_address: "0xaaa",
      symbol: "FUSD",
      decimals: 6,
      quantity: 1,
      currency: "USD"
    )

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test "the database rejects a token row with no contract address" do
    orphan = @item.onchain_wallet_accounts.new(
      chain: OnchainTestHelper::FAKE_CHAIN,
      wallet_address: OnchainTestHelper::FAKE_ADDRESS,
      asset_kind: OnchainTestHelper::FAKE_TOKEN_KIND,
      contract_address: nil,
      symbol: "FUSD",
      decimals: 6,
      quantity: 1,
      currency: "USD"
    )

    # A token is keyed on its contract, and NULLs are distinct to Postgres, so
    # this row would slip past the partial unique index and duplicate freely.
    # The model refuses it too; validate: false proves the table does.
    assert_raises ActiveRecord::StatementInvalid do
      orphan.save!(validate: false)
    end
  end

  test "the database rejects an asset kind no index keys on" do
    odd = @item.onchain_wallet_accounts.new(
      chain: OnchainTestHelper::FAKE_CHAIN,
      wallet_address: OnchainTestHelper::FAKE_ADDRESS,
      asset_kind: "erc721",
      contract_address: "0xccc",
      symbol: "FUSD",
      decimals: 6,
      quantity: 1,
      currency: "USD"
    )

    # Each partial unique index names its kind, so a row carrying another one is
    # keyed by nothing and would duplicate freely.
    assert_raises ActiveRecord::StatementInvalid do
      odd.save!(validate: false)
    end
  end

  test "the database keys a trc20 token on its contract, with case kept" do
    attributes = {
      chain: "tron",
      wallet_address: "TJRabPrwbZy45sbavfcjinPJC18kjpRTv8",
      asset_kind: "trc20",
      symbol: "USDT",
      decimals: 6,
      quantity: 1,
      currency: "USD"
    }
    usdt = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
    @item.onchain_wallet_accounts.create!(attributes.merge(contract_address: usdt))

    assert_equal usdt, @item.onchain_wallet_accounts.find_by!(asset_kind: "trc20").contract_address
    assert_raises ActiveRecord::RecordNotUnique do
      @item.onchain_wallet_accounts.new(attributes.merge(contract_address: usdt)).save!(validate: false)
    end
    # Base58 is case-sensitive: this is a different contract, not a duplicate.
    assert_nothing_raised do
      @item.onchain_wallet_accounts.create!(attributes.merge(contract_address: usdt.downcase))
    end
  end

  test "unlinking the account drops the tracking row and leaves the account manual" do
    onchain_account = create_onchain_wallet_account(item: @item)
    account = accounts(:investment)
    provider_link = onchain_account.ensure_account_provider!(account)
    holding = holdings(:one)
    holding.update!(account_provider: provider_link)

    assert_difference "OnchainWalletAccount.count", -1 do
      account.account_providers.destroy_all
    end

    # What the user asked for is to stop tracking the address, not to lose the
    # account: the Sure account and its holdings stay, as manual ones.
    assert Account.exists?(account.id)
    assert Holding.exists?(holding.id)
    assert_nil holding.reload.account_provider_id
    # Left behind, the row would stop syncing while its partial unique index
    # still held the slot, so linking the same asset again would collide.
    assert_not OnchainWalletAccount.exists?(onchain_account.id)
  end

  test "deleting the account takes the tracking row with it" do
    onchain_account = create_onchain_wallet_account(item: @item)
    account = link_onchain_wallet_account!(onchain_account)

    # Same reasoning as unlinking, by a route that used to miss it: the link is
    # destroyed by the account here rather than by the row, and a guard meant to
    # stop the row destroying itself was catching this case too.
    assert_difference "OnchainWalletAccount.count", -1 do
      account.destroy!
    end

    assert_not OnchainWalletAccount.exists?(onchain_account.id)
  end

  test "a linked account takes its icon from the asset it tracks" do
    # Saved rather than assumed nil: `Setting` is application-wide, and an
    # `ensure` that hard-codes nil erases whatever the suite had configured,
    # leaving every later test's behaviour dependent on run order.
    previous_client_id = Setting.brand_fetch_client_id
    Setting.brand_fetch_client_id = "test-client"
    onchain_account = create_onchain_wallet_account(item: @item)
    account = accounts(:investment)
    onchain_account.ensure_account_provider!(account)

    # There is no institution behind a wallet and nothing attaches a file, so
    # without this the accounts page shows a tracked asset with no icon at all.
    assert_includes account.reload.logo_url.to_s, "/crypto/#{onchain_account.symbol}/"
  ensure
    Setting.brand_fetch_client_id = previous_client_id
  end

  test "a native row and token rows coexist for one address" do
    create_onchain_wallet_account(item: @item)
    create_onchain_wallet_account(item: @item, asset: fake_token_asset(contract: "0xaaa"))
    create_onchain_wallet_account(item: @item, asset: fake_token_asset(symbol: "FDAI", contract: "0xbbb"))

    assert_equal 3, @item.onchain_wallet_accounts.count
  end

  test "the same asset is tracked separately per address" do
    create_onchain_wallet_account(item: @item)
    other = create_onchain_wallet_account(item: @item, address: OnchainTestHelper::FAKE_ADDRESS_ALT)

    assert other.persisted?
    assert_equal 2, @item.onchain_wallet_accounts.count
  end

  test "requires a registered chain" do
    account = @item.onchain_wallet_accounts.new(
      chain: "nosuchchain",
      wallet_address: OnchainTestHelper::FAKE_ADDRESS,
      asset_kind: "native",
      symbol: "FAKE",
      currency: "USD",
      quantity: 1
    )

    assert_not account.valid?
    assert_includes account.errors.attribute_names, :chain
  end

  test "rejects an asset kind the chain does not support" do
    account = @item.onchain_wallet_accounts.new(
      chain: OnchainTestHelper::FAKE_CHAIN,
      wallet_address: OnchainTestHelper::FAKE_ADDRESS,
      asset_kind: "spl",
      contract_address: "0xaaa",
      symbol: "FUSD",
      currency: "USD",
      quantity: 1
    )

    assert_not account.valid?
    assert_includes account.errors.attribute_names, :asset_kind
  end

  test "native rows must not carry a contract and token rows must" do
    native_with_contract = @item.onchain_wallet_accounts.new(
      chain: OnchainTestHelper::FAKE_CHAIN, wallet_address: OnchainTestHelper::FAKE_ADDRESS,
      asset_kind: "native", contract_address: "0xaaa", symbol: "FAKE", currency: "USD", quantity: 1
    )
    token_without_contract = @item.onchain_wallet_accounts.new(
      chain: OnchainTestHelper::FAKE_CHAIN, wallet_address: OnchainTestHelper::FAKE_ADDRESS,
      asset_kind: OnchainTestHelper::FAKE_TOKEN_KIND, symbol: "FUSD", currency: "USD", quantity: 1
    )

    assert_not native_with_contract.valid?
    assert_not token_without_contract.valid?
    assert_includes native_with_contract.errors.attribute_names, :contract_address
    assert_includes token_without_contract.errors.attribute_names, :contract_address
  end

  test "contract addresses are stored downcased so matching is case-insensitive" do
    account = create_onchain_wallet_account(item: @item, asset: fake_token_asset(contract: "0xAbCdEf"))

    assert_equal "0xabcdef", account.contract_address
    assert account.matches_asset?(fake_token_asset(contract: "0xABCDEF"))
    assert_not account.matches_asset?(fake_native_asset)
  end

  test "ordered puts the native asset of each wallet first" do
    token_asset = create_onchain_wallet_account(item: @item, asset: fake_token_asset(symbol: "AAA", contract: "0xaaa"))
    native = create_onchain_wallet_account(item: @item)

    assert_equal [ native.id, token_asset.id ], @item.onchain_wallet_accounts.ordered.map(&:id)
  end

  test "declares raw payloads as encrypted" do
    skip "Encryption not configured" unless OnchainWalletAccount.encryption_ready?

    encrypted = Array(OnchainWalletAccount.encrypted_attributes).map(&:to_s)
    assert_includes encrypted, "raw_payload"
    assert_includes encrypted, "raw_movements_payload"
  end
end

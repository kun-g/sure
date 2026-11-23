# frozen_string_literal: true

require "test_helper"

class Onchain::ChainsTest < ActiveSupport::TestCase
  include OnchainTestHelper, BitcoinExplorerTestHelper

  setup do
    register_fake_chain!
  end

  teardown do
    unregister_fake_chain!
  end

  test "registers and finds a chain" do
    assert Onchain::Chains.exists?(OnchainTestHelper::FAKE_CHAIN)
    assert_equal OnchainTestHelper::FAKE_CHAIN, Onchain::Chains.find(OnchainTestHelper::FAKE_CHAIN).key
    assert_includes Onchain::Chains.keys, OnchainTestHelper::FAKE_CHAIN
  end

  test "unregistering removes the chain" do
    unregister_fake_chain!

    assert_not Onchain::Chains.exists?(OnchainTestHelper::FAKE_CHAIN)
    assert_raises Onchain::Chains::UnknownChainError do
      Onchain::Chains.find!(OnchainTestHelper::FAKE_CHAIN)
    end
  end

  test "refuses a token kind the schema has no unique index for" do
    definition = Onchain::Chains::Definition.new(
      key: "unindexed",
      native: Onchain::Chains::NativeAsset.new(symbol: "UNI", name: "Unindexed", decimals: 18),
      token_kind: "cw20",
      adapter_class_name: "OnchainTestHelper::FakeAdapter",
      adapter_options: {}
    )

    assert_raises Onchain::Chains::Error do
      Onchain::Chains.register(definition)
    end
  ensure
    Onchain::Chains.unregister("unindexed")
  end

  test "builds the adapter with the item credentials" do
    adapter = Onchain::Chains.adapter_for(OnchainTestHelper::FAKE_CHAIN, credentials: { etherscan_api_key: "key" })

    assert_instance_of OnchainTestHelper::FakeAdapter, adapter
    assert_equal "key", adapter.credentials[:etherscan_api_key]
  end

  test "matching returns every chain whose address format accepts the address" do
    matches = Onchain::Chains.matching(OnchainTestHelper::FAKE_ADDRESS)

    assert_equal [ OnchainTestHelper::FAKE_CHAIN ], matches.map(&:key)
    assert_empty Onchain::Chains.matching("not-an-address")
  end

  test "valid_address? returns false for an unregistered chain instead of raising" do
    assert_not Onchain::Chains.valid_address?("nosuchchain", OnchainTestHelper::FAKE_ADDRESS)
  end

  test "native_asset carries the registry metadata" do
    asset = fake_chain.native_asset(quantity: BigDecimal("2"))

    assert asset.native?
    assert_equal "FAKE", asset.symbol
    assert_equal 8, asset.decimals
    assert_nil asset.contract
  end

  test "token_asset uses the chain token kind and raises for chains without tokens" do
    asset = fake_chain.token_asset(symbol: "FUSD", name: "Fake USD", decimals: 6, quantity: 1, contract: "0xAbC")

    assert_equal OnchainTestHelper::FAKE_TOKEN_KIND, asset.kind
    assert_equal "0xabc", asset.contract_key

    unregister_fake_chain!
    register_fake_chain!(token_kind: nil)

    assert_raises Onchain::Chains::Error do
      fake_chain.token_asset(symbol: "FUSD", name: "Fake USD", decimals: 6, quantity: 1, contract: "0xabc")
    end
  end

  test "asset_kinds lists native plus the token kind" do
    assert_equal [ "native", OnchainTestHelper::FAKE_TOKEN_KIND ], fake_chain.asset_kinds
  end

  test "a private key is recognized whatever chain it belongs to" do
    assert Onchain::Chains.private_key?(BIP84_ZPRV)
    assert_not Onchain::Chains.private_key?(BIP84_ZPUB)
    assert_not Onchain::Chains.private_key?("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")
  end

  test "only Bitcoin accepts account keys, and no chain takes one for an address" do
    assert_equal [ Onchain::Chains::BITCOIN ], Onchain::Chains.accepting_account_key(BIP84_XPUB).map(&:key)
    assert_empty Onchain::Chains.accepting_account_key("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq")
    assert_empty Onchain::Chains.matching(BIP84_XPUB)
  end
end

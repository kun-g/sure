# frozen_string_literal: true

require "test_helper"

# A TRON address is Base58 of the same length range as a Solana key, and a legacy
# Bitcoin address falls in it too. These run the real chains, with HTTP stubbed,
# to pin that detection tells the three apart.
class OnchainWalletItem::TronDetectionTest < ActiveSupport::TestCase
  include OnchainTestHelper

  TRON_ADDRESS = "TJRabPrwbZy45sbavfcjinPJC18kjpRTv8"
  BITCOIN_ADDRESS = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
  SOLANA_ADDRESS = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"

  setup do
    Provider::TronGrid.stubs(:sleep)
    Provider::TronGrid.any_instance.stubs(:sleep)
    @item = create_onchain_wallet_item(family: families(:dylan_family))
  end

  test "a TRON address is a candidate for TRON and Solana's shape only" do
    assert_equal %w[solana tron], Onchain::Chains.matching(TRON_ADDRESS).map(&:key).sort
  end

  test "neither a Solana nor a Bitcoin address is a candidate for TRON" do
    assert_not_includes Onchain::Chains.matching(SOLANA_ADDRESS).map(&:key), "tron"
    assert_not_includes Onchain::Chains.matching(BITCOIN_ADDRESS).map(&:key), "tron"
  end

  test "a TRON address that TRON knows is linked to TRON without asking the user" do
    stub_request(:get, "https://api.trongrid.io/v1/accounts/#{TRON_ADDRESS}")
      .to_return(status: 200, body: { data: [ { "balance" => 1 } ] }.to_json, headers: json_headers)

    result = OnchainWalletItem::ChainDetector.new(@item, TRON_ADDRESS).detect

    assert_equal "tron", result.chain
    assert_equal [ "tron" ], result.detected_keys
    # Solana is ruled out by the shape of the key, not by asking its node.
    assert_not_requested :post, Provider::SolanaRpc.url
  end

  test "a TRON address nobody has used yet is left for the user to choose" do
    stub_request(:get, "https://api.trongrid.io/v1/accounts/#{TRON_ADDRESS}")
      .to_return(status: 200, body: { data: [], success: true }.to_json, headers: json_headers)

    result = OnchainWalletItem::ChainDetector.new(@item, TRON_ADDRESS).detect

    assert result.ambiguous?
    assert_empty result.detected_keys
    assert_includes result.candidates.map(&:key), "tron"
  end

  test "a legacy Bitcoin address is settled on Bitcoin without asking Solana's node" do
    result = OnchainWalletItem::ChainDetector.new(@item, BITCOIN_ADDRESS).detect

    assert_equal "bitcoin", result.chain
    assert_not_requested :post, Provider::SolanaRpc.url
    assert_not_requested :get, /trongrid/
  end

  private
    def json_headers
      { "Content-Type" => "application/json" }
    end
end

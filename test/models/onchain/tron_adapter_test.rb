# frozen_string_literal: true

require "test_helper"

class Onchain::TronAdapterTest < ActiveSupport::TestCase
  ADDRESS = "TJRabPrwbZy45sbavfcjinPJC18kjpRTv8"
  OTHER = "TMuA6YqfCeX8EhbfYEg5y7S4DqzSJireY9"
  BITCOIN_ADDRESS = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
  SOLANA_ADDRESS = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
  USDT = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  USDC = "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8"
  # Deployed by someone else, calling itself USDT.
  FAKE_USDT = "TPNXpP6NpaTQPgN7wRo3Q1WAtnmdwQ7WFe"
  BASE = "https://api.trongrid.io"

  setup do
    Provider::TronGrid.stubs(:sleep)
    Provider::TronGrid.any_instance.stubs(:sleep)
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::TRON)
  end

  test "the chain is registered with TRX as its native asset and trc20 tokens" do
    definition = Onchain::Chains.find!("tron")

    assert_equal "TRX", definition.native.symbol
    assert_equal 6, definition.native.decimals
    assert_equal "trc20", definition.token_kind
    assert_equal "TRON", definition.label
    assert Onchain::Chains.contract_case_sensitive?("trc20")
  end

  test "accepts a checksum-valid TRON address and nothing else" do
    assert @adapter.valid_address?(ADDRESS)
    assert @adapter.valid_address?(" #{ADDRESS} ")

    [
      "",
      "short",
      # One character off: the checksum catches what the pattern cannot.
      "#{ADDRESS[0..-2]}9",
      ADDRESS.downcase,
      BITCOIN_ADDRESS,
      SOLANA_ADDRESS,
      "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    ].each do |address|
      assert_not @adapter.valid_address?(address), "#{address.inspect} should be rejected"
    end
  end

  test "an address keeps its exact spelling" do
    assert_equal ADDRESS, @adapter.canonical_address(" #{ADDRESS} ")
  end

  test "fetch_snapshot refuses a malformed address before any request" do
    assert_raises(Onchain::Chains::Error) { @adapter.fetch_snapshot("nope") }
    assert_not_requested :get, /trongrid/
  end

  test "activity is one request, and a known account counts" do
    request = stub_account("balance" => 0)

    assert @adapter.has_activity?(ADDRESS)
    assert_requested request, times: 1
  end

  test "an address TRON has never seen is not activity" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}").to_return(status: 200, body: { data: [], success: true }.to_json, headers: json_headers)

    assert_equal false, @adapter.has_activity?(ADDRESS)
  end

  test "a source that cannot answer is not an empty address" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}").to_return(status: 429, body: "{}", headers: json_headers)

    assert_nil @adapter.has_activity?(ADDRESS)
    assert_requested :get, "#{BASE}/v1/accounts/#{ADDRESS}", times: 1
  end

  test "activity is false without a request for something that is not a TRON address" do
    assert_equal false, @adapter.has_activity?(BITCOIN_ADDRESS)
    assert_not_requested :get, /trongrid/
  end

  test "the balance is TRX in sun and USDT under its real ticker" do
    stub_snapshot(account: { "balance" => 3_500_000, "trc20" => [ { USDT => "5927136" } ] })

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    native = snapshot.find_asset(kind: "native")
    assert_equal "TRX", native.symbol
    assert_equal BigDecimal("3.5"), native.quantity

    usdt = snapshot.find_asset(kind: "trc20", contract: USDT)
    assert_equal "USDT", usdt.symbol
    assert_equal "Tether USD", usdt.name
    assert_equal 6, usdt.decimals
    assert_equal BigDecimal("5.927136"), usdt.quantity
    assert usdt.notable?
    assert_equal "CRYPTO:USDT", Onchain::SecurityResolver.resolve(symbol: usdt.symbol).ticker
    # Listed contracts need no lookup.
    assert_not_requested :post, /triggerconstantcontract/
  end

  test "an address TRON has not seen yet reads as an empty wallet" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}").to_return(status: 200, body: { data: [], success: true }.to_json, headers: json_headers)
    stub_snapshot(account: nil)

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_equal [ BigDecimal("0") ], snapshot.assets.map(&:quantity)
    assert snapshot.find_asset(kind: "native")
  end

  test "a contract that only calls itself USDT gets no ticker and no value" do
    stub_snapshot(account: { "balance" => 0, "trc20" => [ { FAKE_USDT => "25000000" } ] })
    stub_decimals(FAKE_USDT, 6)

    asset = @adapter.fetch_snapshot(ADDRESS).find_asset(kind: "trc20", contract: FAKE_USDT)

    assert_equal BigDecimal("25"), asset.quantity
    assert_no_match(/USDT/, asset.symbol)
    assert_equal "TRC20:TPNX…7WFe", asset.symbol
    assert_not asset.notable?
    assert_nil Onchain::SecurityResolver.resolve(symbol: asset.symbol)
  end

  test "a contract keeps its Base58 case" do
    stub_snapshot(account: { "balance" => 0, "trc20" => [ { USDC => "1000000" } ] })

    asset = @adapter.fetch_snapshot(ADDRESS).find_asset(kind: "trc20", contract: USDC)

    assert_equal USDC, asset.contract
    assert_equal USDC, asset.contract_key
    assert_equal "USDC", asset.symbol
  end

  test "emptied tokens and tokens with absurd supplies are not surfaced" do
    stub_snapshot(account: { "balance" => 1, "trc20" => [
      { USDT => "0" },
      { USDC => "1000000" },
      { FAKE_USDT => "9" * 60 }
    ] })
    stub_decimals(FAKE_USDT, 0)

    contracts = @adapter.fetch_snapshot(ADDRESS).assets.filter_map(&:contract)

    assert_equal [ USDC ], contracts
  end

  test "a token whose decimals cannot be learned is skipped and the read is marked incomplete" do
    stub_snapshot(account: { "balance" => 1, "trc20" => [ { USDT => "1000000" }, { FAKE_USDT => "5" } ] })
    stub_request(:post, "#{BASE}/wallet/triggerconstantcontract").to_return(status: 503)

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_equal "USDT", snapshot.find_asset(kind: "trc20", contract: USDT).symbol
    assert_nil snapshot.find_asset(kind: "trc20", contract: FAKE_USDT)
    assert snapshot.assets_truncated?
  end

  test "only a bounded number of unseen contracts are looked up per sync" do
    contracts = Array.new(Onchain::TronAdapter::MAX_NEW_DECIMAL_LOOKUPS + 3) { |i| "TUnlisted#{format('%024d', i)}" }
    stub_snapshot(account: { "balance" => 1, "trc20" => contracts.map { |contract| { contract => "1000" } } })
    lookups = stub_request(:post, "#{BASE}/wallet/triggerconstantcontract").to_return do |request|
      { status: 200, headers: json_headers, body: { constant_result: [ "6".rjust(64, "0") ] }.to_json }
    end

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_requested lookups, times: Onchain::TronAdapter::MAX_NEW_DECIMAL_LOOKUPS
    assert_equal Onchain::TronAdapter::MAX_NEW_DECIMAL_LOOKUPS, snapshot.assets.count { |asset| !asset.native? }
    assert snapshot.assets_truncated?
  end

  test "decimals are remembered between syncs" do
    stub_snapshot(account: { "balance" => 1, "trc20" => [ { FAKE_USDT => "25000000" } ] })
    lookup = stub_decimals(FAKE_USDT, 6)

    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    2.times { @adapter.fetch_snapshot(ADDRESS) }

    assert_requested lookup, times: 1
  end

  test "an airdrop dump is capped, listed contracts first, the same ones every read" do
    unlisted = %w[TUnlistedAAAAAAAAAAAAAAAAAAAAAAAAA TUnlistedBBBBBBBBBBBBBBBBBBBBBBBBB TUnlistedCCCCCCCCCCCCCCCCCCCCCCCCC]
    stub_snapshot(account: { "balance" => 1, "trc20" => [ *unlisted, USDT ].map { |contract| { contract => "1000000" } } })
    unlisted.each { |contract| stub_decimals(contract, 6) }

    with_env_overrides("ONCHAIN_MAX_TOKENS_PER_ADDRESS" => "2") do
      first = @adapter.fetch_snapshot(ADDRESS)
      second = Onchain::Chains.adapter_for(Onchain::Chains::TRON).fetch_snapshot(ADDRESS)

      assert first.assets_truncated?
      assert_equal [ USDT, unlisted.first ], first.assets.filter_map(&:contract)
      assert_equal first.assets.map(&:contract), second.assets.map(&:contract)
    end
  end

  test "movements are TRX and TRC20 transfers signed from the wallet's point of view" do
    stub_snapshot(
      account: { "balance" => 0 },
      trx: [
        trx_entry(id: "trx_in", from: OTHER, to: ADDRESS, amount: 2_000_000),
        trx_entry(id: "trx_out", from: ADDRESS, to: OTHER, amount: 500_000),
        trx_entry(id: "trx_self", from: ADDRESS, to: ADDRESS, amount: 700_000),
        trx_entry(id: "trx_other", from: OTHER, to: OTHER, amount: 700_000)
      ],
      trc20: [
        trc20_entry(id: "t_in", contract: USDT, from: OTHER, to: ADDRESS, value: "10500000"),
        trc20_entry(id: "t_out", contract: USDT, from: ADDRESS, to: OTHER, value: "500000")
      ]
    )

    movements = @adapter.fetch_snapshot(ADDRESS).movements.index_by(&:external_id)

    assert_equal %w[t_in_TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t t_out_TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t trx_in trx_out].sort, movements.keys.sort
    assert_equal BigDecimal("2"), movements["trx_in"].amount
    assert_equal BigDecimal("-0.5"), movements["trx_out"].amount
    assert_equal "TRX", movements["trx_in"].symbol
    assert_nil movements["trx_in"].contract
    assert_equal BigDecimal("10.5"), movements["t_in_#{USDT}"].amount
    assert_equal BigDecimal("-0.5"), movements["t_out_#{USDT}"].amount
    assert_equal USDT, movements["t_in_#{USDT}"].contract
    assert_equal Time.zone.at(1_700_000_000), movements["trx_in"].timestamp
  end

  test "a transfer of an impostor token is recorded under the placeholder, not the ticker it claims" do
    stub_snapshot(
      account: { "balance" => 0 },
      trc20: [ trc20_entry(id: "spam", contract: FAKE_USDT, from: OTHER, to: ADDRESS, value: "25000000", symbol: "USDT") ]
    )

    movement = @adapter.fetch_snapshot(ADDRESS).movements.first

    assert_equal "TRC20:TPNX…7WFe", movement.symbol
    assert_equal FAKE_USDT, movement.contract
  end

  test "two transfers of one token in one transaction stay two movements" do
    stub_snapshot(
      account: { "balance" => 0 },
      trc20: [
        trc20_entry(id: "tx", contract: USDT, from: OTHER, to: ADDRESS, value: "1000000"),
        trc20_entry(id: "tx", contract: USDT, from: OTHER, to: ADDRESS, value: "2000000")
      ]
    )

    ids = @adapter.fetch_snapshot(ADDRESS).movements.map(&:external_id)

    assert_equal [ "tx_#{USDT}", "tx_#{USDT}_2" ], ids
  end

  test "history is bounded by the shared page budget and reported as incomplete" do
    stub_snapshot(account: { "balance" => 0 })
    paged = stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}/transactions")
      .with(query: hash_including("only_confirmed" => "true"))
      .to_return(status: 200, body: { data: [], meta: { fingerprint: "more" } }.to_json, headers: json_headers)

    with_env_overrides("ONCHAIN_HISTORY_MAX_PAGES" => "2") do
      snapshot = @adapter.fetch_snapshot(ADDRESS)

      assert snapshot.history_truncated?
    end
    assert_requested paged, times: 2
  end

  test "fetch_assets reads balances and tokens and none of the history" do
    stub_snapshot(account: { "balance" => 3_500_000, "trc20" => [ { USDT => "5927136" } ] })

    snapshot = @adapter.fetch_assets(ADDRESS)

    assert_equal BigDecimal("3.5"), snapshot.find_asset(kind: "native").quantity
    assert_equal BigDecimal("5.927136"), snapshot.find_asset(kind: "trc20", contract: USDT).quantity
    assert_empty snapshot.movements
    assert_not snapshot.history_truncated?
    assert_not_requested :get, %r{/transactions}
  end

  test "fetch_assets is one request: listed tokens are shown, unseen ones wait for a sync to learn their decimals" do
    stub_snapshot(account: { "balance" => 1_000_000, "trc20" => [ { USDT => "1000000" }, { FAKE_USDT => "25000000" } ] })
    lookup = stub_decimals(FAKE_USDT, 6)

    snapshot = @adapter.fetch_assets(ADDRESS)

    assert_equal [ nil, USDT ], snapshot.assets.map(&:contract)
    assert_not snapshot.assets_truncated?
    assert_not_requested lookup
    assert_requested :get, "#{BASE}/v1/accounts/#{ADDRESS}", times: 1

    # The sync that follows learns it, and the next review shows it.
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @adapter.fetch_snapshot(ADDRESS)
    assert snapshot_has_contract?(Onchain::Chains.adapter_for(Onchain::Chains::TRON).fetch_assets(ADDRESS), FAKE_USDT)
  end

  test "fetch_assets refuses a malformed address before any request" do
    assert_raises(Onchain::Chains::Error) { @adapter.fetch_assets("nope") }
    assert_not_requested :get, /trongrid/
  end

  test "a source that refuses history still yields the balances" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}")
      .to_return(status: 200, body: { data: [ { "balance" => 4_000_000 } ] }.to_json, headers: json_headers)
    stub_request(:get, %r{#{BASE}/v1/accounts/#{ADDRESS}/transactions}).to_return(status: 429, body: "{}", headers: json_headers)

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_equal BigDecimal("4"), snapshot.find_asset(kind: "native").quantity
    assert_empty snapshot.movements
    assert snapshot.history_truncated?
  end

  test "an unreachable source is reported as unreachable, not as an unexpected failure" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}").to_timeout

    assert_raises(Onchain::Chains::UnreachableError) { @adapter.fetch_snapshot(ADDRESS) }
  end

  test "a throttled source is reported as rate limited" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}").to_return(status: 429, body: "{}", headers: json_headers)

    assert_raises(Onchain::Chains::RateLimitedError) { @adapter.fetch_snapshot(ADDRESS) }
  end

  test "an address the source rejects is an invalid address, not an outage" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}").to_return(status: 400, body: { success: false }.to_json, headers: json_headers)

    error = assert_raises(Onchain::Chains::Error) { @adapter.fetch_snapshot(ADDRESS) }
    assert_not_kind_of Onchain::Chains::UnreachableError, error
  end

  private
    def snapshot_has_contract?(snapshot, contract)
      snapshot.assets.any? { |asset| asset.contract == contract }
    end

    def json_headers
      { "Content-Type" => "application/json" }
    end

    def stub_account(entry)
      stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}")
        .to_return(status: 200, body: { data: [ entry ], success: true }.to_json, headers: json_headers)
    end

    def stub_decimals(contract, decimals)
      stub_request(:post, "#{BASE}/wallet/triggerconstantcontract")
        .with(body: hash_including("contract_address" => contract))
        .to_return(status: 200, body: { constant_result: [ decimals.to_s(16).rjust(64, "0") ] }.to_json, headers: json_headers)
    end

    def stub_snapshot(account:, trx: [], trc20: [])
      stub_account(account) if account
      stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}/transactions")
        .with(query: hash_including("only_confirmed" => "true"))
        .to_return(status: 200, body: { data: trx, meta: {} }.to_json, headers: json_headers)
      stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}/transactions/trc20")
        .with(query: hash_including("only_confirmed" => "true"))
        .to_return(status: 200, body: { data: trc20, meta: {} }.to_json, headers: json_headers)
    end

    def hex_of(address)
      Onchain::BitcoinPublicKey.base58check_decode(address).unpack1("H*")
    end

    def trx_entry(id:, from:, to:, amount:)
      {
        "txID" => id,
        "ret" => [ { "contractRet" => "SUCCESS" } ],
        "block_timestamp" => 1_700_000_000_000,
        "raw_data" => { "contract" => [ {
          "type" => "TransferContract",
          "parameter" => { "value" => { "owner_address" => hex_of(from), "to_address" => hex_of(to), "amount" => amount } }
        } ] }
      }
    end

    def trc20_entry(id:, contract:, from:, to:, value:, symbol: "USDT")
      {
        "transaction_id" => id,
        "token_info" => { "symbol" => symbol, "address" => contract, "decimals" => 6, "name" => "Tether USD" },
        "block_timestamp" => 1_700_000_000_000,
        "from" => from,
        "to" => to,
        "type" => "Transfer",
        "value" => value
      }
    end
end

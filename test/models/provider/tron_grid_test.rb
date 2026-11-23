# frozen_string_literal: true

require "test_helper"

class Provider::TronGridTest < ActiveSupport::TestCase
  ADDRESS = "TJRabPrwbZy45sbavfcjinPJC18kjpRTv8"
  USDT = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  BASE = "https://api.trongrid.io"

  setup do
    Provider::TronGrid.stubs(:sleep)
    Provider::TronGrid.any_instance.stubs(:sleep)
    @provider = Provider::TronGrid.new
  end

  test "account reads the TRX balance in sun and every TRC20 balance" do
    stub_account(
      "balance" => 3_000_000,
      "trc20" => [ { "TPNXpP6NpaTQPgN7wRo3Q1WAtnmdwQ7WFe" => "25000000" }, { USDT => "5927136" } ]
    )

    account = @provider.account(ADDRESS)

    assert_equal 3_000_000, account[:balance]
    assert_equal(
      [ { contract: "TPNXpP6NpaTQPgN7wRo3Q1WAtnmdwQ7WFe", raw_amount: "25000000" }, { contract: USDT, raw_amount: "5927136" } ],
      account[:trc20]
    )
  end

  test "an address the chain has never seen is nil, not an error" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}").to_return(status: 200, body: { data: [], success: true }.to_json, headers: json_headers)

    assert_nil @provider.account(ADDRESS)
  end

  test "an account with no TRX field has a zero balance" do
    stub_account("address" => "41abc")

    assert_equal({ balance: 0, trc20: [] }, @provider.account(ADDRESS))
  end

  test "a 400 means the address was rejected" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}")
      .to_return(status: 400, body: { success: false, error: "A valid account address is required." }.to_json, headers: json_headers)

    assert_raises(Provider::TronGrid::InvalidAddressError) { @provider.account(ADDRESS) }
  end

  test "a rate limited request is retried and then succeeds" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}")
      .to_return({ status: 429, body: { Error: "request rate exceeded the allowed_rps(1)" }.to_json, headers: json_headers })
      .then.to_return(status: 200, body: { data: [ { "balance" => 7 } ] }.to_json, headers: json_headers)

    assert_equal 7, @provider.account(ADDRESS)[:balance]
  end

  test "a rate limit that outlasts the retries raises RateLimitError" do
    request = stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}").to_return(status: 429, body: "{}", headers: json_headers)

    assert_raises(Provider::TronGrid::RateLimitError) { @provider.account(ADDRESS) }
    assert_requested request, times: Provider::TronGrid::MAX_RETRIES + 1
  end

  test "detection can refuse to retry" do
    request = stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}").to_return(status: 429, body: "{}", headers: json_headers)

    assert_raises(Provider::TronGrid::RateLimitError) { Provider::TronGrid.new(max_retries: 0).account(ADDRESS) }
    assert_requested request, times: 1
  end

  test "a throttled answer delivered as a 200 is still a rate limit" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}")
      .to_return(status: 200, body: { Error: "request rate of (getAccount) exceeded the allowed_rps(1)" }.to_json, headers: json_headers)

    assert_raises(Provider::TronGrid::RateLimitError) { Provider::TronGrid.new(max_retries: 0).account(ADDRESS) }
  end

  test "a server error and a dropped connection are both the data source being unavailable" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}").to_return(status: 503)
    assert_raises(Provider::TronGrid::ApiError) { @provider.account(ADDRESS) }

    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}").to_timeout
    assert_raises(Provider::TronGrid::ApiError) { @provider.account(ADDRESS) }
  end

  test "requests wait out the keyless one-per-second limit" do
    stub_account("balance" => 1)
    Provider::TronGrid.instance_variable_set(:@last_request_at, Process.clock_gettime(Process::CLOCK_MONOTONIC))

    Provider::TronGrid.expects(:sleep).with { |seconds| seconds.positive? && seconds <= Provider::TronGrid::KEYLESS_REQUEST_INTERVAL }.once

    @provider.account(ADDRESS)
  end

  test "a configured key is sent and lifts the throttle" do
    stub_account("balance" => 1)

    with_env_overrides("TRONGRID_API_KEY" => "secret-key") do
      assert_equal Provider::TronGrid::KEYED_REQUEST_INTERVAL, Provider::TronGrid.request_interval
      @provider.account(ADDRESS)
    end

    assert_requested :get, "#{BASE}/v1/accounts/#{ADDRESS}", headers: { "TRON-PRO-API-KEY" => "secret-key" }
    assert_equal Provider::TronGrid::KEYLESS_REQUEST_INTERVAL, Provider::TronGrid.request_interval
  end

  test "TRONGRID_URL points the client at another node" do
    request = stub_request(:get, "https://tron.example.test/v1/accounts/#{ADDRESS}")
      .to_return(status: 200, body: { data: [ { "balance" => 1 } ] }.to_json, headers: json_headers)

    with_env_overrides("TRONGRID_URL" => "https://tron.example.test") { @provider.account(ADDRESS) }

    assert_requested request
  end

  test "trx_transfers keeps only successful plain TRX transfers" do
    stub_transactions([
      trx_entry(id: "ok", value: { "owner_address" => "41aa", "to_address" => "41bb", "amount" => 1_500_000 }),
      trx_entry(id: "failed", contract_ret: "REVERT", value: { "owner_address" => "41aa", "to_address" => "41bb", "amount" => 9 }),
      trx_entry(id: "staking", type: "FreezeBalanceV2Contract", value: { "owner_address" => "41aa", "frozen_balance" => 9 })
    ])

    result = @provider.trx_transfers(ADDRESS, max_pages: 3)

    assert_equal [ "ok" ], result[:transfers].map { |transfer| transfer[:id] }
    assert_equal 1_500_000, result[:transfers].first[:amount]
    assert_equal "41bb", result[:transfers].first[:to]
    assert_equal Time.zone.at(1_700_000_000), result[:transfers].first[:timestamp]
    assert_not result[:truncated]
  end

  test "trc20_transfers carries what each contract claims about itself" do
    stub_trc20_transfers([ trc20_entry(id: "t1", contract: USDT, value: "2500000") ])

    transfer = @provider.trc20_transfers(ADDRESS, max_pages: 3)[:transfers].first

    assert_equal(
      { id: "t1", contract: USDT, symbol: "USDT", decimals: 6, from: "TFrom", to: ADDRESS, raw_amount: "2500000", timestamp: Time.zone.at(1_700_000_000) },
      transfer
    )
  end

  test "history follows the cursor until the page budget runs out, and says so" do
    stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}/transactions/trc20")
      .with(query: hash_including("limit" => Provider::TronGrid::PAGE_SIZE.to_s, "only_confirmed" => "true"))
      .to_return do |request|
        fingerprint = Addressable::URI.parse(request.uri.to_s).query_values["fingerprint"]
        page = fingerprint.to_s.delete_prefix("page").to_i
        { status: 200, headers: json_headers,
          body: { data: [ trc20_entry(id: "t#{page}", contract: USDT, value: "1") ], meta: { fingerprint: "page#{page + 1}" } }.to_json }
      end

    result = @provider.trc20_transfers(ADDRESS, max_pages: 3)

    assert_equal %w[t0 t1 t2], result[:transfers].map { |transfer| transfer[:id] }
    assert result[:truncated]
  end

  test "history that ends before the budget is not truncated" do
    stub_trc20_transfers([ trc20_entry(id: "t1", contract: USDT, value: "1") ])

    assert_not @provider.trc20_transfers(ADDRESS, max_pages: 3)[:truncated]
  end

  test "token_decimals reads decimals() from the contract" do
    stub_decimals(USDT, "0000000000000000000000000000000000000000000000000000000000000006")

    assert_equal 6, @provider.token_decimals(USDT)
  end

  test "token_decimals is nil for an address that is not a contract or answers nonsense" do
    request = stub_request(:post, "#{BASE}/wallet/triggerconstantcontract")
      .to_return(status: 200, body: { result: { code: "CONTRACT_VALIDATE_ERROR", message: "Smart contract is not exist." } }.to_json, headers: json_headers)
    assert_nil @provider.token_decimals(ADDRESS)
    assert_requested request

    stub_decimals(USDT, "ff" * 32)
    assert_nil @provider.token_decimals(USDT)
  end

  private
    def json_headers
      { "Content-Type" => "application/json" }
    end

    def stub_account(entry)
      stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}")
        .to_return(status: 200, body: { data: [ entry ], success: true }.to_json, headers: json_headers)
    end

    def stub_transactions(entries)
      stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}/transactions")
        .with(query: hash_including("only_confirmed" => "true"))
        .to_return(status: 200, body: { data: entries, success: true, meta: {} }.to_json, headers: json_headers)
    end

    def stub_trc20_transfers(entries)
      stub_request(:get, "#{BASE}/v1/accounts/#{ADDRESS}/transactions/trc20")
        .with(query: hash_including("only_confirmed" => "true"))
        .to_return(status: 200, body: { data: entries, success: true, meta: {} }.to_json, headers: json_headers)
    end

    def stub_decimals(contract, hex)
      stub_request(:post, "#{BASE}/wallet/triggerconstantcontract")
        .with(body: hash_including("contract_address" => contract, "function_selector" => "decimals()"))
        .to_return(status: 200, body: { result: { result: true }, constant_result: [ hex ] }.to_json, headers: json_headers)
    end

    def trx_entry(id:, value:, type: "TransferContract", contract_ret: "SUCCESS")
      {
        "txID" => id,
        "ret" => [ { "contractRet" => contract_ret } ],
        "block_timestamp" => 1_700_000_000_000,
        "raw_data" => { "contract" => [ { "type" => type, "parameter" => { "value" => value } } ] }
      }
    end

    def trc20_entry(id:, contract:, value:, from: "TFrom", to: ADDRESS, symbol: "USDT")
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

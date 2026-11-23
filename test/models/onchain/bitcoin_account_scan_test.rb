# frozen_string_literal: true

require "test_helper"

class Onchain::BitcoinAccountScanTest < ActiveSupport::TestCase
  include BitcoinExplorerTestHelper

  setup do
    @account = bitcoin_account
  end

  test "an unused account is settled after one gap on each branch" do
    stub_bitcoin_explorer

    scan = scan_account

    assert_summary_requests 40
    assert_empty scan.used
    assert_equal 0, scan.sats
    assert_not scan.truncated?
    assert_requested_address 0, 19
    assert_requested_address 1, 19
    assert_not_requested_address 0, 20
    assert_not_requested_address 1, 20
  end

  test "each branch runs on until the gap that follows its last used address" do
    stub_bitcoin_explorer(transactions: [
      paid("first", [ 0, 0 ], 100),
      paid("at the edge of the gap", [ 0, 20 ], 200),
      paid("change", [ 1, 3 ], 300)
    ])

    scan = scan_account

    # 0..20 used at both ends, then 21..40 unused; 0..3 and then 4..23 unused.
    assert_requested_address 0, 40
    assert_not_requested_address 0, 41
    assert_requested_address 1, 23
    assert_not_requested_address 1, 24
    assert_summary_requests 41 + 24
    assert_equal 600, scan.sats
  end

  test "an address beyond the gap is not found" do
    stub_bitcoin_explorer(transactions: [ paid("too far", [ 0, 20 ], 100) ])

    assert_equal 0, scan_account.sats
  end

  test "a spent or merely pending address still counts as used" do
    elsewhere = "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"
    stub_bitcoin_explorer(transactions: [
      paid("pending", [ 0, 19 ], 50, confirmed: false),
      bitcoin_transaction("emptied", inputs: [ [ @account.address(0, 10), 100 ] ], outputs: [ [ elsewhere, 90 ] ]),
      paid("received", [ 0, 10 ], 100)
    ])

    scan = scan_account

    assert_equal [ @account.address(0, 10), @account.address(0, 19) ], scan.used.keys
    assert_equal 50, scan.sats
    assert_requested_address 0, 39
    assert_not_requested_address 0, 40
  end

  test "every address it looked at is known to be the wallet's, used or not" do
    stub_bitcoin_explorer

    addresses = scan_account.addresses

    assert_includes addresses, @account.address(0, 0)
    assert_includes addresses, @account.address(1, 19)
    assert_not_includes addresses, @account.address(0, 20)
  end

  test "a longer gap is a setting" do
    stub_bitcoin_explorer(transactions: [ paid("far", [ 0, 20 ], 100) ])

    with_env("ONCHAIN_GAP_LIMIT" => "30") { assert_equal 100, scan_account.sats }
  end

  test "a scan that runs out of budget says so, having read both branches alike" do
    stub_bitcoin_explorer(transactions: [ paid("receive", [ 0, 5 ], 100), paid("change", [ 1, 5 ], 200) ])

    scan = with_env("ONCHAIN_MAX_ADDRESSES_PER_WALLET" => "44") { scan_account }

    assert scan.truncated?
    assert_summary_requests 44
    assert_requested_address 0, 21
    assert_requested_address 1, 21
    assert_equal 300, scan.sats
  end

  test "a budget that is exactly enough is not a truncated scan" do
    stub_bitcoin_explorer

    scan = with_env("ONCHAIN_MAX_ADDRESSES_PER_WALLET" => "40") { scan_account }

    assert_not scan.truncated?
  end

  # An answer without the figures is the explorer failing, not an unused address:
  # taken for one, it would end the scan early and zero the wallet.
  test "an unreadable summary is never taken for an unused address" do
    Provider::MempoolSpace.any_instance.stubs(:throttle_request)

    [ {}, { "chain_stats" => {} }, [], nil, "down for maintenance" ].each do |body|
      stub_request(:get, %r{/address/}).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })

      assert_raises(Onchain::Chains::UnreachableError, body.inspect) { scan_account }
    end
  end

  private
    def scan_account
      Onchain::BitcoinAccountScan.new(@account, provider: Provider::MempoolSpace.new).perform
    end

    def paid(txid, (branch, index), sats, **options)
      bitcoin_transaction(txid, outputs: [ [ @account.address(branch, index), sats ] ], **options)
    end

    def assert_requested_address(branch, index)
      assert_requested(:get, "#{Provider::MempoolSpace.base_url}/address/#{@account.address(branch, index)}", times: 1)
    end

    def assert_not_requested_address(branch, index)
      assert_not_requested(:get, "#{Provider::MempoolSpace.base_url}/address/#{@account.address(branch, index)}")
    end
end

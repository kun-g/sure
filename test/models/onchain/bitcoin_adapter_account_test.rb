# frozen_string_literal: true

require "test_helper"

# The half of the Bitcoin adapter that reads a whole account from its extended
# public key. A single address is covered by Onchain::BitcoinAdapterTest.
class Onchain::BitcoinAdapterAccountTest < ActiveSupport::TestCase
  include BitcoinExplorerTestHelper

  ELSEWHERE = "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"

  setup do
    @adapter = Onchain::Chains.adapter_for(Onchain::Chains::BITCOIN)
    @account = bitcoin_account
  end

  test "recognizes extended public keys, and refuses them as addresses" do
    [ BIP84_ZPUB, BIP84_XPUB, " #{BIP84_XPUB} ", "tpubD6NzVbkrYhZ4XgiXtGrdW5XDAPFCL9h7we1vwNCpn8tGbBcgfVYjXyhWo4E1xkh56hjod1RhGjxbaTLV3X4FyWuejifB9jusQ46QzG87VKp" ].each do |key|
      assert @adapter.account_key?(key), key
      assert_not @adapter.valid_address?(key), key
    end

    [ ELSEWHERE, BIP84_ZPRV, "xpub", "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", "" ].each do |value|
      assert_not @adapter.account_key?(value), value
    end
  end

  test "recognizes private keys" do
    assert @adapter.private_key?(BIP84_ZPRV)
    assert_not @adapter.private_key?(BIP84_ZPUB)
  end

  test "the balance is every derived address together, mempool included" do
    stub_bitcoin_explorer(transactions: [
      bitcoin_transaction("pending", outputs: [ [ @account.address(0, 1), 25_000_000 ] ], confirmed: false),
      bitcoin_transaction("change", outputs: [ [ @account.address(1, 0), 50_000_000 ] ]),
      bitcoin_transaction("received", outputs: [ [ @account.address(0, 0), 100_000_000 ] ])
    ])

    snapshot = @adapter.fetch_account_snapshot(@account)

    asset = snapshot.assets.sole
    assert asset.native?
    assert_equal "BTC", asset.symbol
    assert_equal BigDecimal("1.75"), asset.quantity
    assert_not snapshot.history_truncated?
    assert_not snapshot.addresses_truncated?
  end

  %w[p2pkh p2sh_p2wpkh p2wpkh p2tr].each do |script_type|
    test "reads a #{script_type} account" do
      account = bitcoin_account(script_type)
      stub_bitcoin_explorer(transactions: [
        bitcoin_transaction("received", outputs: [ [ account.address(0, 0), 100_000_000 ] ])
      ])

      snapshot = @adapter.fetch_account_snapshot(account)

      assert_equal 1, snapshot.assets.sole.quantity
      assert_equal 1, snapshot.movements.sole.amount
    end
  end

  test "a transaction entirely inside the wallet is neither income nor expense" do
    stub_bitcoin_explorer(transactions: [
      # A consolidation into change, paying a fee.
      bitcoin_transaction("consolidated",
        inputs: [ [ @account.address(0, 0), 60_000_000 ], [ @account.address(0, 1), 40_000_000 ] ],
        outputs: [ [ @account.address(1, 0), 99_990_000 ], [ nil, 0 ] ]),
      bitcoin_transaction("received",
        outputs: [ [ @account.address(0, 0), 60_000_000 ], [ @account.address(0, 1), 40_000_000 ] ])
    ])

    snapshot = @adapter.fetch_account_snapshot(@account)

    assert_equal [ "received" ], snapshot.movements.map(&:external_id)
    # The fee is gone from the balance, where it is a fact.
    assert_equal BigDecimal("0.9999"), snapshot.assets.sole.quantity
  end

  test "change to an address nobody has used yet is still the wallet's own" do
    stub_bitcoin_explorer(transactions: [
      bitcoin_transaction("spent",
        inputs: [ [ @account.address(0, 0), 100_000_000 ] ],
        outputs: [ [ ELSEWHERE, 30_000_000 ], [ @account.address(1, 7), 69_990_000 ] ]),
      bitcoin_transaction("received", outputs: [ [ @account.address(0, 0), 100_000_000 ] ])
    ])

    movements = @adapter.fetch_account_snapshot(@account).movements.index_by(&:external_id)

    assert_equal BigDecimal("1"), movements["received"].amount
    # What left the wallet: the payment and its fee, not the change.
    assert_equal BigDecimal("-0.3001"), movements["spent"].amount
  end

  test "a transaction touching several of the wallet's addresses is one movement" do
    stub_bitcoin_explorer(transactions: [
      bitcoin_transaction("spent",
        inputs: [ [ @account.address(0, 0), 10_000_000 ], [ @account.address(0, 1), 20_000_000 ] ],
        outputs: [ [ ELSEWHERE, 25_000_000 ], [ @account.address(1, 0), 4_000_000 ] ]),
      bitcoin_transaction("second", outputs: [ [ @account.address(0, 1), 20_000_000 ] ]),
      bitcoin_transaction("first", outputs: [ [ @account.address(0, 0), 10_000_000 ] ])
    ])

    movements = @adapter.fetch_account_snapshot(@account).movements

    assert_equal %w[first second spent], movements.map(&:external_id).sort
    assert_equal BigDecimal("-0.26"), movements.find { |movement| movement.external_id == "spent" }.amount
    assert_equal BigDecimal("0.04"), movements.sum(&:amount)
  end

  test "coins a wallet only partly funded count for its own share" do
    stub_bitcoin_explorer(transactions: [
      bitcoin_transaction("joint",
        inputs: [ [ @account.address(0, 0), 10_000_000 ], [ ELSEWHERE, 50_000_000 ] ],
        outputs: [ [ @account.address(0, 1), 59_000_000 ] ]),
      bitcoin_transaction("received", outputs: [ [ @account.address(0, 0), 10_000_000 ] ])
    ])

    movements = @adapter.fetch_account_snapshot(@account).movements.index_by(&:external_id)

    assert_equal BigDecimal("0.49"), movements["joint"].amount
  end

  test "an unconfirmed transaction is dated today" do
    stub_bitcoin_explorer(transactions: [
      bitcoin_transaction("pending", outputs: [ [ @account.address(0, 0), 1_000_000 ] ], confirmed: false)
    ])

    assert_equal Date.current, @adapter.fetch_account_snapshot(@account).movements.sole.date
  end

  test "an address whose transactions were all seen costs no history request" do
    stub_bitcoin_explorer(transactions: [
      bitcoin_transaction("spent",
        inputs: [ [ @account.address(0, 0), 100_000_000 ] ],
        outputs: [ [ ELSEWHERE, 30_000_000 ], [ @account.address(1, 0), 69_990_000 ] ]),
      bitcoin_transaction("received", outputs: [ [ @account.address(0, 0), 100_000_000 ] ])
    ])

    @adapter.fetch_account_snapshot(@account)

    assert_history_requests 1
  end

  test "one address's history is bounded like any other address's" do
    stub_bitcoin_explorer(transactions: Array.new(60) { |i|
      bitcoin_transaction("tx#{i}", outputs: [ [ @account.address(0, 0), 1_000 ] ])
    })

    snapshot = with_env("ONCHAIN_HISTORY_MAX_PAGES" => "2") { @adapter.fetch_account_snapshot(@account) }

    assert snapshot.history_truncated?
    assert_not snapshot.addresses_truncated?
    assert_equal 50, snapshot.movements.size
    assert_equal 60_000, snapshot.assets.sole.quantity * 100_000_000
  end

  test "the wallet's history as a whole is bounded by the address budget" do
    transactions = Array.new(3) { |index|
      Array.new(60) { |i| bitcoin_transaction("tx#{index}-#{i}", outputs: [ [ @account.address(0, index), 1_000 ] ]) }
    }.flatten
    stub_bitcoin_explorer(transactions: transactions)
    Onchain::AddressScanBudget.stubs(:history_pages).returns(4)

    snapshot = @adapter.fetch_account_snapshot(@account)

    assert_history_requests 4
    assert snapshot.history_truncated?
    assert_equal 85, snapshot.movements.size
  end

  # Without the rest of the addresses there is no telling a payment from change,
  # and a movement written wrongly is not taken back by a later, complete read.
  test "a truncated address scan keeps the partial balance and records no movements" do
    stub_bitcoin_explorer(transactions: [ bitcoin_transaction("received", outputs: [ [ @account.address(0, 5), 100_000_000 ] ]) ])

    snapshot = with_env("ONCHAIN_MAX_ADDRESSES_PER_WALLET" => "40") { @adapter.fetch_account_snapshot(@account) }

    assert snapshot.history_truncated?
    assert snapshot.addresses_truncated?
    assert_equal 1, snapshot.assets.sole.quantity
    assert_empty snapshot.movements
    assert_history_requests 0
  end

  test "an explorer that refuses history still yields the balance" do
    stub_bitcoin_explorer(transactions: [ bitcoin_transaction("received", outputs: [ [ @account.address(0, 0), 100_000_000 ] ]) ])
    Provider::MempoolSpace.any_instance.stubs(:sleep)
    stub_request(:get, %r{/address/[^/]+/txs}).to_return(status: 429)

    snapshot = @adapter.fetch_account_snapshot(@account)

    assert_equal 1, snapshot.assets.sole.quantity
    assert_empty snapshot.movements
    assert snapshot.history_truncated?
    assert_not snapshot.addresses_truncated?
  end

  test "history read before the explorer gave up is kept" do
    stub_bitcoin_explorer(transactions: [
      bitcoin_transaction("second", outputs: [ [ @account.address(0, 1), 100_000_000 ] ]),
      bitcoin_transaction("first", outputs: [ [ @account.address(0, 0), 100_000_000 ] ])
    ])
    stub_request(:get, "#{Provider::MempoolSpace.base_url}/address/#{@account.address(0, 1)}/txs").to_timeout

    snapshot = @adapter.fetch_account_snapshot(@account)

    assert_equal [ "first" ], snapshot.movements.map(&:external_id)
    assert snapshot.history_truncated?
  end

  test "a throttled scan is a rate limit, not an empty wallet" do
    Provider::MempoolSpace.any_instance.stubs(:throttle_request)
    Provider::MempoolSpace.any_instance.stubs(:sleep)
    stub_request(:get, %r{/address/}).to_return(status: 429)

    assert_raises(Onchain::Chains::RateLimitedError) { @adapter.fetch_account_snapshot(@account) }
  end

  test "a scan the explorer cannot answer is unreachable, not an empty wallet" do
    Provider::MempoolSpace.any_instance.stubs(:throttle_request)
    stub_request(:get, %r{/address/}).to_timeout

    assert_raises(Onchain::Chains::UnreachableError) { @adapter.fetch_account_snapshot(@account) }
  end

  test "what can be tracked is known without asking the explorer" do
    # WebMock raises on any unstubbed request.
    asset = @adapter.account_preview.assets.sole

    assert_equal "BTC", asset.symbol
    assert_nil asset.quantity
  end

  test "a stored key is read back as the account it was linked as" do
    account = @adapter.account_for(BIP84_XPUB, "p2tr")

    assert_equal bitcoin_account("p2tr").reference, account.reference
    assert_raises(Onchain::Chains::Error) { @adapter.account_for(BIP84_ZPUB, "p2tr") }
    assert_raises(Onchain::Chains::Error) { @adapter.account_for(BIP84_XPUB, nil) }
  end
end

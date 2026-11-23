# frozen_string_literal: true

# A stubbed Bitcoin explorer holding whatever addresses a test gives it. Every
# address it was not told about exists and is unused, which is what a real
# explorer answers for a freshly derived one.
module BitcoinExplorerTestHelper
  # The public BIP84 test vector account, never a user's key.
  BIP84_ZPUB = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs"
  # The same account with xpub version bytes, which state no script type.
  BIP84_XPUB = "xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V"
  # Its private half, published in BIP84.
  BIP84_ZPRV = "zprvAdG4iTXWBoARxkkzNpNh8r6Qag3irQB8PzEMkAFeTRXxHpbF9z4QgEvBRmfvqWvGp42t42nvgGpNgYSJA9iefm1yYNZKEm7z6qUWCroSQnE"

  def bitcoin_account(script_type = "p2wpkh")
    Onchain::BitcoinAccount.for(BIP84_XPUB).find { |account| account.script_type == script_type }
  end

  # A tracked account, the way the linking flow leaves it.
  def create_bitcoin_account_row(item:, account: bitcoin_account, **attrs)
    item.onchain_wallet_accounts.create!({
      chain: Onchain::Chains::BITCOIN,
      wallet_address: account.reference,
      extended_public_key: account.extended_public_key,
      script_type: account.script_type,
      asset_kind: "native",
      symbol: "BTC",
      name: "Bitcoin",
      decimals: 8,
      quantity: 0,
      currency: item.family.currency
    }.merge(attrs))
  end

  # transactions: what each transaction says, newest first, as the API lists them.
  # Address summaries are derived from them, so the two cannot disagree.
  def stub_bitcoin_explorer(transactions: [])
    Provider::MempoolSpace.any_instance.stubs(:throttle_request)

    stub_request(:get, %r{\A#{Regexp.escape(Provider::MempoolSpace.base_url)}/address/[^/]+\z}).to_return do |request|
      json_response(explorer_summary(request.uri.path.split("/").last, transactions))
    end

    stub_request(:get, %r{\A#{Regexp.escape(Provider::MempoolSpace.base_url)}/address/[^/]+/txs\z}).to_return do |request|
      json_response(explorer_history(request.uri.path.split("/")[-2], transactions).first(Provider::MempoolSpace::PAGE_SIZE))
    end

    stub_request(:get, %r{\A#{Regexp.escape(Provider::MempoolSpace.base_url)}/address/[^/]+/txs/chain/[^/]+\z}).to_return do |request|
      *, address, _txs, _chain, last_txid = request.uri.path.split("/")
      history = explorer_history(address, transactions)
      json_response(history.drop(history.index { |tx| tx["txid"] == last_txid } + 1).first(Provider::MempoolSpace::PAGE_SIZE))
    end
  end

  # inputs and outputs: [[address, sats], ...]
  def bitcoin_transaction(txid, inputs: [], outputs: [], date: Date.new(2026, 1, 2), confirmed: true)
    {
      "txid" => txid,
      "vin" => inputs.map { |address, sats| { "prevout" => { "scriptpubkey_address" => address, "value" => sats } } },
      "vout" => outputs.map { |address, sats| { "scriptpubkey_address" => address, "value" => sats } },
      "status" => confirmed ? { "confirmed" => true, "block_time" => date.to_time(:utc).to_i } : { "confirmed" => false }
    }
  end

  def assert_summary_requests(count)
    assert_requested(:get, %r{/address/[^/]+\z}, times: count)
  end

  def assert_history_requests(count)
    assert_requested(:get, %r{/address/[^/]+/txs}, times: count)
  end

  def with_env(values)
    previous = values.keys.index_with { |key| ENV[key] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  private
    def json_response(body)
      { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
    end

    def explorer_history(address, transactions)
      transactions.select { |tx| (explorer_inputs(tx) + tx["vout"]).any? { |output| output["scriptpubkey_address"] == address } }
    end

    def explorer_summary(address, transactions)
      confirmed, pending = explorer_history(address, transactions).partition { |tx| tx.dig("status", "confirmed") }

      { "address" => address, "chain_stats" => explorer_stats(address, confirmed), "mempool_stats" => explorer_stats(address, pending) }
    end

    def explorer_stats(address, transactions)
      {
        "tx_count" => transactions.size,
        "funded_txo_sum" => explorer_sum(address, transactions.flat_map { |tx| tx["vout"] }),
        "spent_txo_sum" => explorer_sum(address, transactions.flat_map { |tx| explorer_inputs(tx) })
      }
    end

    def explorer_inputs(transaction)
      transaction["vin"].filter_map { |input| input["prevout"] }
    end

    def explorer_sum(address, outputs)
      outputs.sum { |output| output["scriptpubkey_address"] == address ? output["value"] : 0 }
    end
end

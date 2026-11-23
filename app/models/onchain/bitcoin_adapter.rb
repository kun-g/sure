# frozen_string_literal: true

# Bitcoin, read from a single address or from a whole HD account.
#
# Bitcoin has no account balances: an address owns unspent outputs, so the
# balance is everything ever paid to it minus everything spent from it. Mempool
# totals are included, because a spend that is broadcast but unconfirmed has
# already left the wallet as far as the owner is concerned.
#
# A Bitcoin wallet is normally an HD wallet: one account key derives any number of
# addresses and change goes to derived ones, so a single address under-reports
# such a wallet. Given the account's extended public key, its addresses are derived
# here and looked up one by one (see Onchain::BitcoinAccountScan), and everything is
# reported for the wallet as a whole: one balance, and one movement per transaction
# that crossed its edge.
class Onchain::BitcoinAdapter
  include Onchain::ChainAdapter

  SATS_PER_BTC = 100_000_000.to_d

  # An extended public key of any network, up to 112 characters of Base58.
  ACCOUNT_KEY_PATTERN = /\A[a-zA-Z]pub[1-9A-HJ-NP-Za-km-z]{20,}\z/

  def initialize(credentials: {})
    @credentials = credentials
  end

  # Checksum-verified, so a mistyped address is refused instead of syncing as empty.
  def valid_address?(address)
    Onchain::BitcoinPublicKey.valid_address?(address.to_s.strip)
  end

  # Bech32 is case-insensitive and canonically lowercase — and the API reports it
  # that way, so an uppercase input would otherwise match no output and silently
  # produce zero movements. Base58 is case-sensitive and must be left alone.
  def canonical_address(address)
    Onchain::BitcoinPublicKey.canonical_address(address)
  end

  def private_key?(value)
    Onchain::BitcoinPublicKey.private_key?(value)
  end

  # By shape alone, so that a key of another network or a mistyped one is answered
  # as a key that cannot be used rather than as an address nobody recognizes.
  def account_key?(value)
    value.to_s.strip.match?(ACCOUNT_KEY_PATTERN)
  end

  def accounts_for(value)
    Onchain::BitcoinAccount.for(value)
  end

  def account_for(value, script_type)
    Onchain::BitcoinAccount.new(value, script_type)
  end

  # Bitcoin has nothing but its native coin to track, so this takes no request. The
  # scan is one request per derived address, far more than a page can wait for.
  def account_preview
    Onchain::Snapshot.new(assets: [ definition.native_asset(quantity: nil) ], movements: [])
  end

  def fetch_account_snapshot(account)
    wrap_provider_errors do
      scan = Onchain::BitcoinAccountScan.new(account, provider: provider).perform

      # Without all of the wallet's addresses a payment cannot be told from change,
      # and a movement recorded wrongly stays in the account's history.
      transactions, complete = scan.truncated? ? [ [], false ] : account_transactions(scan)

      Onchain::Snapshot.new(
        assets: [ definition.native_asset(quantity: scan.sats / SATS_PER_BTC) ],
        movements: movements_from(transactions, scan.addresses) { |transaction| internal?(transaction, scan.addresses) },
        history_truncated: !complete,
        addresses_truncated: scan.truncated?
      )
    end
  end

  def fetch_snapshot(address)
    raise Onchain::Chains::Error, "Invalid Bitcoin address" unless valid_address?(address)

    wrap_provider_errors do
      summary = provider.get_address(address)

      movements = best_effort_movements { movements_for(address) }

      Onchain::Snapshot.new(
        assets: [ definition.native_asset(quantity: balance_from(summary)) ],
        movements: movements || [],
        history_truncated: movements.nil? || provider.truncated
      )
    end
  end

  def provider_error_classes
    [ Provider::MempoolSpace::RateLimitError, Provider::MempoolSpace::Error ]
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!(Onchain::Chains::BITCOIN)
    end

    def provider
      @provider ||= Provider::MempoolSpace.new(max_pages: Onchain::HistoryBudget.pages)
    end

    # Confirmed plus mempool: funded minus spent.
    def balance_from(summary)
      sats = %w[chain_stats mempool_stats].sum do |scope|
        stats = summary.to_h.fetch(scope, {}).to_h
        stats.fetch("funded_txo_sum", 0).to_d - stats.fetch("spent_txo_sum", 0).to_d
      end

      sats / SATS_PER_BTC
    end

    def movements_for(address)
      movements_from(provider.get_address_transactions(address), Set[address])
    end

    # Reads the wallet's history address by address, within both the budget of one
    # address and that of the wallet.
    #
    # A transaction carries all of its inputs and outputs, so whichever address it
    # was found through, it says everything there is to know about it. That is why
    # an address all of whose transactions were already seen is not asked about,
    # and why what was read before the explorer gave up is worth keeping.
    # @return [Array(Array, Boolean)] the transactions, and whether they are all of them
    def account_transactions(scan)
      transactions = {}
      seen = Hash.new(0)
      pages_left = Onchain::AddressScanBudget.history_pages
      complete = true

      finished = best_effort_movements do
        scan.used.each do |address, count|
          next if seen[address] >= count

          if pages_left.zero?
            complete = false
            break
          end

          provider.get_address_transactions(address, max_pages: [ Onchain::HistoryBudget.pages, pages_left ].min).each do |transaction|
            next if transactions.key?(transaction["txid"])

            transactions[transaction["txid"]] = transaction
            touched_addresses(transaction).each { |touched| seen[touched] += 1 }
          end
          pages_left -= provider.pages_read
          complete &&= !provider.truncated
        end

        true
      end

      [ transactions.values, finished.present? && complete ]
    end

    # Skips the transactions the block picks out, and those that leave the wallet
    # with what it had.
    def movements_from(transactions, addresses)
      transactions.filter_map do |transaction|
        next if block_given? && yield(transaction)

        amount = net_amount(transaction, addresses)
        next if amount.zero?

        Onchain::Movement.new(
          external_id: transaction["txid"],
          symbol: definition.native.symbol,
          contract: nil,
          amount: amount,
          timestamp: transaction_date(transaction)
        )
      end
    end

    # What the addresses gained or lost in this transaction: outputs paid to them
    # minus the inputs they funded. A transaction that only moves coins between
    # them nets to zero and is dropped.
    def net_amount(transaction, addresses)
      received = Array(transaction["vout"]).sum { |output| value_for(output, addresses) }
      sent = inputs(transaction).sum { |input| value_for(input, addresses) }

      (received - sent) / SATS_PER_BTC
    end

    # Coins moved from the wallet to itself, which is neither income nor spending.
    # The fee leaves the wallet, so this is not the same as netting to zero. Outputs
    # worth nothing (OP_RETURN) pay nobody.
    def internal?(transaction, addresses)
      inputs = inputs(transaction)
      outputs = Array(transaction["vout"]).select { |output| output["value"].to_i.positive? }

      inputs.any? && (inputs + outputs).all? { |output| addresses.include?(address_of(output)) }
    end

    def touched_addresses(transaction)
      (inputs(transaction) + Array(transaction["vout"])).map { |output| address_of(output) }.uniq
    end

    # What each input spent. A coinbase input spends nothing and has no address.
    def inputs(transaction)
      Array(transaction["vin"]).map { |input| input["prevout"] }
    end

    def address_of(output)
      output["scriptpubkey_address"].to_s if output.is_a?(Hash)
    end

    def value_for(output, addresses)
      addresses.include?(address_of(output)) ? output["value"].to_d : 0.to_d
    end

    # Unconfirmed transactions have no block time; they happened now.
    def transaction_date(transaction)
      block_time = transaction.dig("status", "block_time")
      return Date.current if block_time.blank?

      Time.zone.at(block_time.to_i).to_date
    end
end

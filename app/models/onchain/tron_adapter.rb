# frozen_string_literal: true

# TRON: TRX and TRC20 tokens.
#
# One request to the account endpoint answers the TRX balance and every TRC20
# balance, but it reports tokens by contract only — no symbol, no decimals. And
# a TRC20 contract is a few lines anyone can deploy under any name: a wallet's
# history routinely holds a "USDT" that is not Tether's. So a ticker is given
# only to the contracts listed in TRUSTED_TOKENS, which also carry the decimals;
# any other token is tracked by quantity under a label that cannot pass for a
# ticker and is valued at zero, never at the price of the asset it imitates.
#
# TronGrid's keyless tier is one request per second, so what a sync reads is
# bounded: transfer history by Onchain::HistoryBudget, and the number of
# unlisted tokens whose decimals are looked up fresh by MAX_NEW_DECIMAL_LOOKUPS.
class Onchain::TronAdapter
  include Onchain::ChainAdapter

  SUN_PER_TRX = 1_000_000.to_d

  # Base58Check of 0x41 followed by a 20-byte hash: always 34 characters, always
  # starting with "T". The pattern alone also matches a Solana-shaped string, so
  # validity additionally requires the checksum.
  ADDRESS_PATTERN = /\AT[1-9A-HJ-NP-Za-km-z]{33}\z/
  ADDRESS_PREFIX = 0x41

  # The contracts allowed a real ticker, with their decimals. Deliberately
  # short: a wrong entry would value a holding as an unrelated asset.
  TRUSTED_TOKENS = {
    "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" => { symbol: "USDT", name: "Tether USD", decimals: 6 },
    "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8" => { symbol: "USDC", name: "USD Coin", decimals: 6 }
  }.freeze

  MAX_NEW_DECIMAL_LOOKUPS = 10
  DECIMALS_CACHE_TTL = 30.days

  # quantity is stored as numeric(32, 18): a spam token minted with an absurd
  # supply must be skipped, not allowed to fail the write of the whole wallet.
  MAX_QUANTITY = 10.to_d**13

  def initialize(credentials: {})
    @credentials = credentials
  end

  def valid_address?(address)
    text = address.to_s.strip
    return false unless ADDRESS_PATTERN.match?(text)

    payload = Onchain::BitcoinPublicKey.base58check_decode(text)
    payload&.bytesize == 21 && payload.getbyte(0) == ADDRESS_PREFIX
  rescue StandardError
    false
  end

  # One request: TronGrid has no record of an address until it first receives
  # something, so a known account is activity enough. A refusal or timeout is
  # not an empty answer — see Onchain::ChainAdapter#has_activity?.
  def has_activity?(address)
    return false unless valid_address?(address)

    !detection_provider.account(address).nil?
  rescue StandardError => e
    Rails.logger.warn("Onchain::TronAdapter - activity probe failed: #{e.class}")
    nil
  end

  def fetch_snapshot(address)
    read(address, history: true)
  end

  # TronGrid's keyless tier serves one request per second, and history is up to
  # twenty pages of them, plus one request per unlisted token for its decimals:
  # far too slow for a screen that is waiting on the answer. This is one request.
  # Unlisted tokens appear once a background sync has learned their decimals.
  def fetch_assets(address)
    read(address, history: false)
  end

  def provider_error_classes
    [ Provider::TronGrid::RateLimitError, Provider::TronGrid::Error ]
  end

  private
    attr_reader :credentials

    def read(address, history:)
      raise Onchain::Chains::Error, "Invalid TRON address" unless valid_address?(address)

      wrap_provider_errors do
        account = provider.account(address) || { balance: 0, trc20: [] }
        tokens = token_assets(account[:trc20], new_lookups: history ? MAX_NEW_DECIMAL_LOOKUPS : 0)
        movements = history ? best_effort_movements { movements(address) } : []

        Onchain::Snapshot.new(
          assets: [ definition.native_asset(quantity: account[:balance].to_d / SUN_PER_TRX), *tokens ],
          movements: movements || [],
          history_truncated: history && (movements.nil? || @history_truncated),
          assets_truncated: @assets_truncated
        )
      rescue Provider::TronGrid::InvalidAddressError
        raise Onchain::Chains::Error, "Invalid TRON address"
      end
    end

    def definition
      Onchain::Chains.find!(Onchain::Chains::TRON)
    end

    def provider
      @provider ||= Provider::TronGrid.new
    end

    # Detection runs on the request thread, so it reads with the detection
    # budget rather than the sync's: one short attempt, no retry.
    def detection_provider
      @detection_provider ||= Provider::TronGrid.new(
        request_timeout: Onchain::DetectionBudget.timeout,
        max_retries: Onchain::DetectionBudget.retries
      )
    end

    # Listed contracts first, then the rest ordered by contract, so the cap
    # removes the same tokens between two reads of an unchanged address. A token
    # whose decimals cannot be learned has no quantity to report; it counts as
    # not surfaced, which tells the importer it was not read rather than empty.
    def token_assets(balances, new_lookups:)
      held = balances
        .select { |balance| raw_value(balance[:raw_amount]).positive? }
        .uniq { |balance| balance[:contract] }
        .sort_by { |balance| [ TRUSTED_TOKENS.key?(balance[:contract]) ? 0 : 1, balance[:contract] ] }

      @lookups_left = new_lookups
      surfaced = held.first(Onchain::AssetBudget.tokens)
      assets = surfaced.filter_map { |balance| token_asset(balance) }
      # Without lookups an unresolved token is simply not known yet, which is not
      # the same as the address holding more than one read surfaces.
      @assets_truncated = held.size > surfaced.size || (new_lookups.positive? && assets.size < surfaced.size)

      assets
    end

    def token_asset(balance)
      contract = balance[:contract]
      decimals = token_decimals(contract)
      return nil if decimals.nil?

      quantity = raw_value(balance[:raw_amount]) / (10.to_d**decimals)
      return nil if quantity.zero? || quantity >= MAX_QUANTITY

      listed = TRUSTED_TOKENS[contract]
      definition.token_asset(
        symbol: token_symbol(contract),
        name: listed ? listed[:name] : "TRC20 token #{contract}",
        decimals: decimals,
        quantity: quantity,
        contract: contract,
        notable: listed.present?
      )
    end

    def raw_value(raw_amount)
      BigDecimal(raw_amount.to_s.presence || "0")
    rescue ArgumentError
      0.to_d
    end

    def token_symbol(contract)
      TRUSTED_TOKENS.dig(contract, :symbol) || "TRC20:#{contract.first(4)}…#{contract.last(4)}"
    end

    # A contract's decimals never change, so they are cached for good measure
    # and only a bounded number of unseen contracts is asked about per sync.
    def token_decimals(contract)
      return TRUSTED_TOKENS[contract][:decimals] if TRUSTED_TOKENS.key?(contract)

      cache_key = "onchain:tron_decimals:#{contract}"
      cached = Rails.cache.read(cache_key)
      return cached unless cached.nil?
      return nil unless @lookups_left.positive?

      @lookups_left -= 1
      decimals = provider.token_decimals(contract)
      Rails.cache.write(cache_key, decimals, expires_in: DECIMALS_CACHE_TTL) unless decimals.nil?
      decimals
    rescue Provider::TronGrid::Error => e
      Rails.logger.warn("Onchain::TronAdapter - decimals unavailable: #{e.class}")
      nil
    end

    def movements(address)
      pages = Onchain::HistoryBudget.pages
      wallet = Onchain::BitcoinPublicKey.base58check_decode(address).unpack1("H*")

      trx = provider.trx_transfers(address, max_pages: pages)
      trc20 = provider.trc20_transfers(address, max_pages: pages)
      @history_truncated = trx[:truncated] || trc20[:truncated]

      [ *trx_movements(trx[:transfers], wallet), *trc20_movements(trc20[:transfers], address) ]
    end

    def trx_movements(transfers, wallet)
      transfers.filter_map do |transfer|
        next if transfer[:from] == transfer[:to]

        sign = transfer[:to] == wallet ? 1 : (transfer[:from] == wallet ? -1 : nil)
        next if sign.nil? || transfer[:amount].zero?

        Onchain::Movement.new(
          external_id: transfer[:id],
          symbol: definition.native.symbol,
          contract: nil,
          amount: sign * transfer[:amount].to_d / SUN_PER_TRX,
          timestamp: transfer[:timestamp]
        )
      end
    end

    # One transaction can move several tokens, and one token more than once, so
    # the id carries the contract and, for a repeat, its position.
    def trc20_movements(transfers, address)
      seen = Hash.new(0)

      transfers.filter_map do |transfer|
        next if transfer[:from] == transfer[:to]

        sign = transfer[:to] == address ? 1 : (transfer[:from] == address ? -1 : nil)
        decimals = TRUSTED_TOKENS.dig(transfer[:contract], :decimals) || transfer[:decimals]
        next if sign.nil? || !decimals.between?(0, 36)

        amount = raw_value(transfer[:raw_amount]) / (10.to_d**decimals)
        next if amount.zero? || amount >= MAX_QUANTITY

        occurrence = seen[[ transfer[:id], transfer[:contract] ]] += 1
        Onchain::Movement.new(
          external_id: [ transfer[:id], transfer[:contract], (occurrence if occurrence > 1) ].compact.join("_"),
          symbol: token_symbol(transfer[:contract]),
          contract: transfer[:contract],
          amount: sign * amount,
          timestamp: transfer[:timestamp]
        )
      end
    end
end

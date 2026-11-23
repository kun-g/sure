# frozen_string_literal: true

# Keyless TRON data source backed by TronGrid's public HTTP API.
#
# A dumb client: the token trust model and the mapping into an
# Onchain::Snapshot both live in Onchain::TronAdapter. Self-hosters can point it
# at their own node or a paid plan with TRONGRID_URL and TRONGRID_API_KEY.
#
# Without a key TronGrid allows one request per second per IP and suspends the
# caller for five seconds when that is exceeded, so every request in the process
# goes through one shared throttle instead of relying on retries to recover.
class Provider::TronGrid
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class InvalidAddressError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  DEFAULT_URL = "https://api.trongrid.io"

  KEYLESS_REQUEST_INTERVAL = 1.1
  KEYED_REQUEST_INTERVAL = 0.1
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 2
  PAGE_SIZE = 50
  API_KEY_HEADER = "TRON-PRO-API-KEY"

  # Any well-formed account works as the caller of a read-only contract call.
  CALLER_ADDRESS = "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb"

  THROTTLE_LOCK = Mutex.new
  @last_request_at = nil

  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  class << self
    def base_url
      ENV["TRONGRID_URL"].presence || DEFAULT_URL
    end

    def api_key
      ENV["TRONGRID_API_KEY"].presence
    end

    def request_interval
      api_key ? KEYED_REQUEST_INTERVAL : KEYLESS_REQUEST_INTERVAL
    end

    # Process-wide: the limit is per caller, not per client object, and a sync
    # plus a detection probe can overlap.
    def throttle
      THROTTLE_LOCK.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        remaining = request_interval - (now - (@last_request_at || -request_interval))
        sleep(remaining) if remaining.positive?
        @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end

  # Detection reads on the request thread and cannot afford the sync's patience,
  # so both the per-request timeout and the retry count are the caller's to set.
  def initialize(request_timeout: nil, max_retries: MAX_RETRIES)
    @request_timeout = request_timeout
    @max_retries = max_retries
  end

  # @return [Hash, nil] { balance: Integer (sun), trc20: [{ contract:, raw_amount: }] },
  #   or nil for an address the chain has never seen: TRON creates an account when
  #   it first receives something, and TronGrid answers an empty list until then.
  def account(address)
    entry = Array(get_json("/v1/accounts/#{encode(address)}")["data"]).first
    return nil unless entry.is_a?(Hash)

    {
      balance: entry["balance"].to_i,
      trc20: Array(entry["trc20"]).flat_map do |balances|
        balances.to_h.map { |contract, raw_amount| { contract: contract.to_s, raw_amount: raw_amount.to_s } }
      end
    }
  end

  # Transaction records of the wallet, newest first. Only TRX transfers are
  # returned; every other contract type (staking, resource delegation, smart
  # contract calls) is not a movement of the wallet's TRX balance.
  # @return [Hash] { transfers: [{ id:, from:, to:, amount: (sun), timestamp: Time }], truncated: }
  def trx_transfers(address, max_pages:)
    entries, truncated = paginate("/v1/accounts/#{encode(address)}/transactions", max_pages: max_pages)

    transfers = entries.filter_map do |entry|
      contract = Array(entry.dig("raw_data", "contract")).first.to_h
      next unless contract["type"] == "TransferContract"
      next unless Array(entry["ret"]).first.to_h["contractRet"] == "SUCCESS"

      value = contract.dig("parameter", "value").to_h
      next if entry["txID"].blank? || entry["block_timestamp"].blank?

      {
        id: entry["txID"],
        from: value["owner_address"].to_s.downcase,
        to: value["to_address"].to_s.downcase,
        amount: value["amount"].to_i,
        timestamp: Time.zone.at(entry["block_timestamp"].to_i / 1000)
      }
    end

    { transfers: transfers, truncated: truncated }
  end

  # @return [Hash] { transfers: [{ id:, contract:, symbol:, decimals:, from:, to:, raw_amount:, timestamp: Time }], truncated: }
  #   `symbol` and `decimals` are whatever the token's own contract claims: any
  #   contract can call itself USDT, so the adapter decides what to trust.
  def trc20_transfers(address, max_pages:)
    entries, truncated = paginate("/v1/accounts/#{encode(address)}/transactions/trc20", max_pages: max_pages)

    transfers = entries.filter_map do |entry|
      info = entry["token_info"].to_h
      next unless entry["type"] == "Transfer"
      next if entry["transaction_id"].blank? || info["address"].blank? || entry["block_timestamp"].blank?

      {
        id: entry["transaction_id"],
        contract: info["address"],
        symbol: info["symbol"].to_s,
        decimals: info["decimals"].to_i,
        from: entry["from"].to_s,
        to: entry["to"].to_s,
        raw_amount: entry["value"].to_s,
        timestamp: Time.zone.at(entry["block_timestamp"].to_i / 1000)
      }
    end

    { transfers: transfers, truncated: truncated }
  end

  # The token contract's own decimals(), or nil when it has none.
  def token_decimals(contract)
    body = post_json(
      "/wallet/triggerconstantcontract",
      owner_address: CALLER_ADDRESS,
      contract_address: contract,
      function_selector: "decimals()",
      visible: true
    )
    hex = Array(body["constant_result"]).first.to_s
    return nil unless hex.match?(/\A[0-9a-f]{1,64}\z/)

    decimals = hex.to_i(16)
    decimals if decimals <= 36
  end

  private
    # Follows TronGrid's fingerprint cursor for at most `max_pages` pages.
    # `truncated` is true when the budget ran out before the last page.
    def paginate(path, max_pages:)
      entries = []
      fingerprint = nil
      max_pages.times do
        body = get_json(path, { limit: PAGE_SIZE, only_confirmed: true, fingerprint: fingerprint }.compact)
        entries.concat(Array(body["data"]))
        fingerprint = body.dig("meta", "fingerprint").presence
        return [ entries, false ] if fingerprint.nil?
      end

      [ entries, true ]
    end

    def encode(value)
      ERB::Util.url_encode(value)
    end

    def get_json(path, query = {})
      request { self.class.get("#{self.class.base_url}#{path}", **request_options(query: query)) }
    end

    def post_json(path, payload)
      request { self.class.post("#{self.class.base_url}#{path}", **request_options(body: payload.to_json)) }
    end

    def request
      attempts = 0

      begin
        attempts += 1
        self.class.throttle
        translate_transport_errors { handle_response(yield) }
      rescue RateLimitError => e
        raise if attempts > @max_retries

        Rails.logger.warn("Provider::TronGrid - rate limited (attempt #{attempts}/#{@max_retries}): #{e.message}")
        sleep(RETRY_BASE_DELAY * (2**(attempts - 1)))
        retry
      end
    end

    def request_options(**options)
      headers = { "Content-Type" => "application/json" }
      headers[API_KEY_HEADER] = self.class.api_key if self.class.api_key

      options = options.merge(headers: headers)
      @request_timeout.nil? ? options : options.merge(timeout: @request_timeout)
    end

    def handle_response(response)
      raise RateLimitError, "TronGrid rate limit exceeded" if response.code == 429
      raise InvalidAddressError, "TronGrid rejected the address" if response.code == 400
      raise ApiError, "TronGrid API error: #{response.code}" unless response.code.between?(200, 299)

      body = response.parsed_response
      raise ApiError, "Unexpected TronGrid response" unless body.is_a?(Hash)
      # Some throttled answers arrive as a 200 carrying only an "Error" message.
      raise RateLimitError, "TronGrid rate limit exceeded" if body["Error"].to_s.match?(/rate|quota/i)
      raise ApiError, "TronGrid API error" if body["success"] == false || body.key?("Error")

      body
    end
end

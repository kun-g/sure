# frozen_string_literal: true

# The contract every chain implementation fulfils. An adapter is the only
# place in the codebase allowed to know how a specific chain works; it turns
# that knowledge into an Onchain::Snapshot and nothing else.
module Onchain::ChainAdapter
  # @param address [String]
  # @return [Boolean] whether the address is well-formed for this chain.
  #   Must never make a network call.
  def valid_address?(_address)
    raise NotImplementedError, "#{self.class} must implement #valid_address?"
  end

  # The form of an address this chain considers canonical, so that two spellings
  # of the same address cannot become two wallets. Case matters on some chains and
  # not others, which is why only the adapter can answer it.
  def canonical_address(address)
    address.to_s.strip
  end

  # @param address [String]
  # @return [Onchain::Snapshot]
  def fetch_snapshot(_address)
    raise NotImplementedError, "#{self.class} must implement #fetch_snapshot"
  end

  # What the address holds, without the transfer history. The linking and token
  # review screens run on the request thread and only need assets, so a chain
  # whose history is slow to read should override this. The default reads
  # everything.
  # @param address [String]
  # @return [Onchain::Snapshot]
  def fetch_assets(address)
    fetch_snapshot(address)
  end

  # Whether the input is a secret that could spend from a wallet. It is refused
  # before anything else looks at it. Must never make a network call.
  def private_key?(_value)
    false
  end

  # Whether the input is an account-level public key, from which this chain can
  # follow a whole wallet. Must never make a network call.
  def account_key?(_value)
    false
  end

  # The accounts an account key may stand for. Each answers #script_type,
  # #extended_public_key, #reference, #first_address and #covers?(address). More
  # than one means the key alone does not settle it, and only its owner can.
  # @raise [Onchain::Chains::Error] when the key cannot be used
  def accounts_for(_value)
    raise NotImplementedError, "#{self.class} must implement #accounts_for"
  end

  # The account a key was linked as.
  # @raise [Onchain::Chains::Error] when the two do not go together
  def account_for(_value, _script_type)
    raise NotImplementedError, "#{self.class} must implement #account_for"
  end

  # What can be tracked in an account, answered without any request and so with no
  # quantities: reading an account is too slow to do while a page waits.
  # @return [Onchain::Snapshot]
  def account_preview
    raise NotImplementedError, "#{self.class} must implement #account_preview"
  end

  # @return [Onchain::Snapshot] everything the account's addresses hold together
  def fetch_account_snapshot(_account)
    raise NotImplementedError, "#{self.class} must implement #fetch_account_snapshot"
  end

  # The error classes this chain's data sources raise, as
  # [rate limit class(es), base class(es)]. Either entry may be a single class or
  # an array, because a chain may read through more than one backend.
  def provider_error_classes
    []
  end

  # Translates a data source's own errors into Onchain::Chains errors. Anything
  # else — a bug in our code — is left alone so it surfaces as the unexpected
  # failure it is instead of being reported to the user as a dead explorer.
  def wrap_provider_errors
    yield
  rescue Onchain::Chains::Error
    raise
  rescue StandardError => e
    rate_limit_classes, base_classes = provider_error_classes
    raise Onchain::Chains::RateLimitedError, e.message if Array(rate_limit_classes).any? { |klass| e.is_a?(klass) }
    raise Onchain::Chains::UnreachableError, e.message if Array(base_classes).any? { |klass| e.is_a?(klass) }

    raise
  end

  # Reads transfer history without letting its failure cost the balances.
  #
  # A balance is one bounded request and is what a wallet fundamentally is;
  # history is paginated, an order of magnitude more expensive, and the first
  # thing a throttled public endpoint refuses. Failing the whole snapshot over it
  # means a wallet that could have been valued correctly shows nothing at all —
  # on some free endpoints, permanently.
  #
  # Returns nil when the history could not be read, which the caller reports as
  # an incomplete history rather than as an empty one. Anything that is not the
  # data source failing still raises: a bug here must not be silently swallowed.
  def best_effort_movements
    yield
  rescue Onchain::Chains::Error
    raise
  rescue StandardError => e
    rate_limit_classes, base_classes = provider_error_classes
    known = Array(rate_limit_classes).any? { |klass| e.is_a?(klass) } ||
      Array(base_classes).any? { |klass| e.is_a?(klass) }
    raise unless known

    Rails.logger.warn("#{self.class.name} - history unavailable, keeping balances only: #{e.class}")
    nil
  end

  # Whether this address is worth tracking on this chain, answered with at most
  # ONE bounded request and never by reading paginated history. Only chains that
  # share an address format with other chains (every EVM network) need to
  # override this; elsewhere a well-formed address is answer enough.
  #
  # Three answers, not two: true, false, and nil for "could not tell" — a source
  # that timed out or refused has not reported an empty address. An override
  # that collapses the third into false lets detection settle on another chain
  # without asking, which is how a wallet gets linked to the wrong network.
  def has_activity?(address)
    valid_address?(address)
  end
end

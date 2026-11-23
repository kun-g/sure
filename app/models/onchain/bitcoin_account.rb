# frozen_string_literal: true

# One HD account: an account-level public key together with the script type its
# wallet uses, which are only meaningful as a pair — the same xpub derives four
# unrelated sets of addresses, one per script type.
class Onchain::BitcoinAccount
  # The BIP that defines each script type's derivation, which is how wallets and
  # their owners name them.
  SCHEMES = {
    Onchain::BitcoinPublicKey::P2PKH => "bip44",
    Onchain::BitcoinPublicKey::P2SH_P2WPKH => "bip49",
    Onchain::BitcoinPublicKey::P2WPKH => "bip84",
    Onchain::BitcoinPublicKey::P2TR => "bip86"
  }.freeze

  RECEIVE = 0
  CHANGE = 1
  BRANCHES = [ RECEIVE, CHANGE ].freeze

  # How many addresses of each branch are derived to recognize one. Local
  # arithmetic, so deeper than a wallet's gap limit at no cost to the explorer.
  LOOKUP_DEPTH = 100

  class << self
    # Every account an extended public key may stand for: one when its version
    # bytes state the script type, four when they do not.
    def for(value)
      key = public_key(value)

      key.script_types.map { |script_type| new(value, script_type, public_key: key) }
    end

    def public_key(value)
      Onchain::BitcoinPublicKey.new(value)
    rescue Onchain::BitcoinPublicKey::InvalidKey => e
      raise Onchain::Chains::Error, e.message
    end
  end

  attr_reader :extended_public_key, :script_type

  def initialize(extended_public_key, script_type, public_key: self.class.public_key(extended_public_key))
    raise Onchain::Chains::Error, "Invalid script type" unless public_key.script_types.include?(script_type)

    @extended_public_key = extended_public_key.to_s.strip
    @script_type = script_type
    @public_key = public_key
  end

  def address(branch, index)
    public_key.address(branch, index, script_type: script_type)
  end

  # The address a wallet shows first on its receive screen, and so the one its
  # owner can recognize the account by.
  def first_address
    address(RECEIVE, 0)
  end

  # Identifies the account without revealing it, so that the key itself never has
  # to appear in a URL, a log or a list.
  def reference
    "#{SCHEMES.fetch(script_type)}:#{public_key.fingerprint.first(32)}"
  end

  # Whether an address is among the first this account derives.
  def covers?(candidate)
    candidate = Onchain::BitcoinPublicKey.canonical_address(candidate)
    return false unless Onchain::BitcoinPublicKey.script_type_of(candidate) == script_type

    BRANCHES.any? { |branch| LOOKUP_DEPTH.times.any? { |index| address(branch, index) == candidate } }
  end

  # Never the key.
  def inspect
    "#<#{self.class.name} #{reference}>"
  end

  private
    attr_reader :public_key
end

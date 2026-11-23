# frozen_string_literal: true

module Onchain
  # An account-level mainnet key and the addresses it derives.
  #
  # A key says nothing about which kind of address its wallet uses, except
  # through its version bytes: SLIP-132 gives ypub and zpub one script type each,
  # while xpub is exported for all of them. `script_types` is therefore what the
  # key *may* stand for, and an address is never derived for a type nobody chose.
  class BitcoinPublicKey
    class InvalidKey < ArgumentError; end

    # BIP44, BIP49, BIP84 and BIP86, in that order.
    P2PKH = "p2pkh"
    P2SH_P2WPKH = "p2sh_p2wpkh"
    P2WPKH = "p2wpkh"
    P2TR = "p2tr"
    SCRIPT_TYPES = [ P2PKH, P2SH_P2WPKH, P2WPKH, P2TR ].freeze

    # Mainnet xpub, ypub and zpub.
    VERSIONS = {
      "0488b21e" => SCRIPT_TYPES,
      "049d7cb2" => [ P2SH_P2WPKH ].freeze,
      "04b24746" => [ P2WPKH ].freeze
    }.freeze
    PREFIXES = %w[xpub ypub zpub].freeze

    P2PKH_VERSION = 0x00
    P2SH_VERSION = 0x05

    # By shape rather than by checksum: a mistyped private key is still a private
    # key. BIP32 and SLIP-132 private prefixes of any network, inside an output
    # descriptor too, and WIF.
    PRIVATE_KEY_PATTERN = /\b[xyztuvYZUV]prv[1-9A-HJ-NP-Za-km-z]|\A\s*[5KL][1-9A-HJ-NP-Za-km-z]{50,51}\s*\z/

    BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    CURVE = OpenSSL::PKey::EC::Group.new("secp256k1")

    # What this key may stand for, going by its version bytes alone.
    attr_reader :script_types

    # Parse a mainnet account-level xpub/ypub/zpub and reject private keys, wrong
    # depths and unsupported encodings before any address derivation occurs.
    def initialize(value)
      text = value.to_s.strip
      raise InvalidKey, "Use a mainnet account xpub, ypub or zpub" unless text.length <= 112 && text.start_with?(*PREFIXES)

      # version(4) depth(1) parent fingerprint(4) child number(4) chain code(32) key(33)
      payload = self.class.base58check_decode(text)
      raise InvalidKey, "Invalid extended public key" unless payload&.bytesize == 78 && VERSIONS.key?(payload[0, 4].unpack1("H*"))
      # Hardened account node: m/purpose'/0'/n' (depth 3) or Electrum's segwit m/0' (depth 1).
      depth, child = payload.getbyte(4), payload[9, 4].unpack1("N")
      raise InvalidKey, "Use an account-level extended public key" unless depth == 3 ? child >= 0x80000000 : depth == 1 && child == 0x80000000

      @script_types = VERSIONS.fetch(payload[0, 4].unpack1("H*"))
      @chain_code = payload[13, 32]
      @pub = payload[45, 33]
      OpenSSL::PKey::EC::Point.new(CURVE, @pub) # rejects private keys and off-curve points
    rescue StandardError => error
      raise InvalidKey, "Invalid extended public key" unless error.is_a?(InvalidKey)
      raise
    end

    # Derive an address on receive (0) or change (1), allowing only non-hardened
    # child indices obtainable from an account public key. The script type may be
    # left out only where the key itself settles it.
    def address(branch, index, script_type: (script_types.first if script_types.one?))
      raise InvalidKey, "Invalid derivation branch" unless [ 0, 1 ].include?(branch)
      raise InvalidKey, "Invalid address index" unless index.between?(0, 0x7fffffff)
      raise InvalidKey, "Choose the script type of this key" unless script_types.include?(script_type)

      @branches ||= {}
      child, = derive(*(@branches[branch] ||= derive(@pub, @chain_code, branch)), index)
      encode(child, script_type)
    end

    # Identify public key material independently of its xpub/zpub version bytes,
    # so equivalent encodings cannot create duplicate sources. The key is hashed
    # as hex and the chain code as bytes, matching fingerprints already stored
    # by the #3753 preview.
    def fingerprint
      Digest::SHA256.hexdigest(@pub.unpack1("H*") + @chain_code)
    end

    # Validate the checksum and a standard mainnet output (P2PKH, P2SH, P2WPKH,
    # P2WSH, P2TR); malformed addresses and other networks return false.
    def self.valid_address?(value)
      text = value.to_s
      return false unless text.length.between?(26, 90)

      if text.match?(/\Abc1/i)
        segwit = Bech32::SegwitAddr.new(text)
        segwit.hrp == "bc" && (segwit.ver.zero? ? [ 20, 32 ].include?(segwit.prog.size) : segwit.ver == 1 && segwit.prog.size == 32)
      else
        payload = base58check_decode(text)
        payload&.bytesize == 21 && [ 0x00, 0x05 ].include?(payload.getbyte(0))
      end
    rescue StandardError
      false
    end

    # The script type an address was made with, or nil for one no supported
    # account derives (P2WSH, other networks, malformed). A 3... address may also
    # wrap another script; only finding it among a key's addresses settles that.
    def self.script_type_of(value)
      return nil unless valid_address?(value)

      text = value.to_s
      return text.start_with?("1") ? P2PKH : P2SH_P2WPKH unless text.match?(/\Abc1/i)

      segwit = Bech32::SegwitAddr.new(text)
      return P2TR if segwit.ver == 1

      P2WPKH if segwit.prog.size == 20
    end

    def self.private_key?(value)
      value.to_s.match?(PRIVATE_KEY_PATTERN)
    end

    # Trim input and normalize uniformly cased Bech32 addresses. Keep mixed case
    # unchanged so checksum validation rejects it rather than silently repairing it.
    def self.canonical_address(value)
      text = value.to_s.strip
      text.start_with?("BC1") && text == text.upcase ? text.downcase : text
    end

    # Decode Base58Check, returning nil when the checksum does not match.
    def self.base58check_decode(text)
      number = text.each_char.reduce(0) { |sum, char| sum * 58 + (BASE58.index(char) || raise(ArgumentError, "Invalid Base58")) }
      hex = number.zero? ? "" : number.to_s(16)
      bytes = ("\x00" * text[/\A1*/].size + [ hex.rjust(hex.size + hex.size % 2, "0") ].pack("H*")).b
      payload = bytes[0...-4]
      payload if bytes.bytesize > 4 && bytes[-4..] == OpenSSL::Digest.digest("SHA256", OpenSSL::Digest.digest("SHA256", payload))[0, 4]
    end

    def self.base58check_encode(payload)
      bytes = payload + OpenSSL::Digest.digest("SHA256", OpenSSL::Digest.digest("SHA256", payload))[0, 4]
      number = bytes.unpack1("H*").to_i(16)
      digits = +""
      while number.positive?
        number, remainder = number.divmod(58)
        digits << BASE58[remainder]
      end

      BASE58[0] * bytes[/\A\x00*/n].bytesize + digits.reverse
    end

    # Never the key material: this object ends up in error reports and consoles.
    def inspect
      "#<#{self.class.name}>"
    end

    private
      def encode(pub, script_type)
        case script_type
        when P2PKH then base58check(P2PKH_VERSION, hash160(pub))
        when P2SH_P2WPKH then base58check(P2SH_VERSION, hash160("\x00\x14".b + hash160(pub)))
        when P2WPKH then segwit_address(0, hash160(pub))
        when P2TR then segwit_address(1, taproot_output_key(pub))
        end
      end

      # BIP86: the output key commits to no script path, so the internal key is
      # tweaked by the hash of itself alone (BIP341). x-only keys stand for the
      # point with even y, whatever the parity of the derived key.
      def taproot_output_key(pub)
        internal = pub[1, 32]
        tag = OpenSSL::Digest.digest("SHA256", "TapTweak")
        tweak = OpenSSL::BN.new(OpenSSL::Digest.digest("SHA256", tag + tag + internal), 2)
        raise InvalidKey, "Invalid derived key" if tweak >= CURVE.order

        point = CURVE.generator.mul(tweak).add(OpenSSL::PKey::EC::Point.new(CURVE, "\x02".b + internal))
        raise InvalidKey, "Invalid derived key" if point.infinity?

        point.to_octet_string(:compressed)[1, 32]
      end

      def segwit_address(version, program)
        segwit = Bech32::SegwitAddr.new
        segwit.ver = version
        segwit.prog = program.bytes
        segwit.addr
      end

      def base58check(version, hash)
        self.class.base58check_encode([ version ].pack("C") + hash)
      end

      def hash160(data)
        OpenSSL::Digest.digest("RIPEMD160", OpenSSL::Digest.digest("SHA256", data))
      end

      # BIP32 public child derivation (CKDpub) for a non-hardened index.
      def derive(pub, chain_code, index)
        digest = OpenSSL::HMAC.digest("SHA512", chain_code, pub + [ index ].pack("N"))
        tweak = OpenSSL::BN.new(digest[0, 32], 2)
        raise InvalidKey, "Invalid derived key" if tweak >= CURVE.order

        point = CURVE.generator.mul(tweak).add(OpenSSL::PKey::EC::Point.new(CURVE, pub))
        raise InvalidKey, "Invalid derived key" if point.infinity?

        [ point.to_octet_string(:compressed), digest[32, 32] ]
      end
  end
end

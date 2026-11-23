require "test_helper"

class Onchain::BitcoinPublicKeyTest < ActiveSupport::TestCase
  # Public BIP84 test vectors (BIP84 spec), never a user's keys.
  ZPUB = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs"
  RECEIVE = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"
  SECOND = "bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g"
  CHANGE = "bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el"

  # The same BIP84 test account key with xpub version bytes instead of zpub.
  XPUB = "xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V"

  # The accounts of the public BIP39 phrase "abandon ... about" that the BIP84
  # and BIP86 vectors are derived from. BIP44 publishes no address vector, so its
  # addresses (and BIP49's mainnet ones) were computed with embit 0.8.0.
  BIP44_XPUB = "xpub6BosfCnifzxcFwrSzQiqu2DBVTshkCXacvNsWGYJVVhhawA7d4R5WSWGFNbi8Aw6ZRc1brxMyWMzG3DSSSSoekkudhUd9yLb6qx39T9nMdj"
  BIP49_YPUB = "ypub6Ww3ibxVfGzLrAH1PNcjyAWenMTbbAosGNB6VvmSEgytSER9azLDWCxoJwW7Ke7icmizBMXrzBx9979FfaHxHcrArf3zbeJJJUZPf663zsP"
  BIP49_XPUB = "xpub6C6nQwHaWbSrzs5tZ1q7m5R9cPK9eYpNMFesiXsYrgc1P8bvLLAet9JfHjYXKjToD8cBRswJXXbbFpXgwsswVPAZzKMa1jUp2kVkGVUaJa7"
  BIP86_XPUB = "xpub6BgBgsespWvERF3LHQu6CnqdvfEvtMcQjYrcRzx53QJjSxarj2afYWcLteoGVky7D3UKDP9QyrLprQ3VCECoY49yfdDEHGCtMMj92pReUsQ"

  VECTORS = {
    "p2pkh" => [ BIP44_XPUB, %w[1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA 1Ak8PffB2meyfYnbXZR9EGfLfFZVpzJvQP 1J3J6EvPrv8q6AC3VCjWV45Uf3nssNMRtH] ],
    "p2sh_p2wpkh" => [ BIP49_YPUB, %w[37VucYSaXLCAsxYyAPfbSi9eh4iEcbShgf 3LtMnn87fqUeHBUG414p9CWwnoV6E2pNKS 34K56kSjgUCUSD8GTtuF7c9Zzwokbs6uZ7] ],
    "p2wpkh" => [ ZPUB, [ RECEIVE, SECOND, CHANGE ] ],
    "p2tr" => [ BIP86_XPUB, %w[
      bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr
      bc1p4qhjn9zdvkux4e44uhx8tc55attvtyu358kutcqkudyccelu0was9fqzwh
      bc1p3qkhfews2uk44qtvauqyr2ttdsw7svhkl9nkm9s9c3x4ax5h60wqwruhk7
    ] ]
  }.freeze

  VECTORS.each do |script_type, (extended_key, addresses)|
    test "derives the published #{script_type} receive and change addresses" do
      key = Onchain::BitcoinPublicKey.new(extended_key)

      assert_includes key.script_types, script_type
      assert_equal addresses, [ [ 0, 0 ], [ 0, 1 ], [ 1, 0 ] ].map { |branch, index| key.address(branch, index, script_type: script_type) }
    end

    test "an address of #{script_type} names its own script type" do
      addresses.each { |address| assert_equal script_type, Onchain::BitcoinPublicKey.script_type_of(address) }
    end
  end

  # BIP49 publishes testnet vectors only: the same account key with mainnet
  # version bytes has to reproduce the published script hash.
  test "derives the script hash of the official BIP49 vector" do
    key = Onchain::BitcoinPublicKey.new("ypub6XaXJjyZ5oda7d4Etzuc5q3fs9YvEocqUa1pBdK67x4v3Cknh6oJHqEfbZtF6QR1HEdTWnec5mdrF1EYmhg4iTxm1nGVww7dzszLLVUuXzr")

    payload = Onchain::BitcoinPublicKey.base58check_decode(key.address(0, 0))

    assert_equal "05" + "336caa13e08b96080a32b5d818d59b4ab3b36742", payload.unpack1("H*")
  end

  test "an xpub can stand for any script type and is never given one" do
    key = Onchain::BitcoinPublicKey.new(XPUB)

    assert_equal %w[p2pkh p2sh_p2wpkh p2wpkh p2tr], key.script_types
    assert_raises(Onchain::BitcoinPublicKey::InvalidKey) { key.address(0, 0) }
    assert_raises(Onchain::BitcoinPublicKey::InvalidKey) { key.address(0, 0, script_type: "p2wsh") }
  end

  test "ypub and zpub state their script type and accept no other" do
    { BIP49_YPUB => "p2sh_p2wpkh", ZPUB => "p2wpkh" }.each do |extended_key, script_type|
      key = Onchain::BitcoinPublicKey.new(extended_key)

      assert_equal [ script_type ], key.script_types
      assert_raises(Onchain::BitcoinPublicKey::InvalidKey) { key.address(0, 0, script_type: "p2tr") }
    end
  end

  test "an xpub spelling of a BIP49 account derives the same addresses" do
    assert_equal VECTORS["p2sh_p2wpkh"].last.first,
                 Onchain::BitcoinPublicKey.new(BIP49_XPUB).address(0, 0, script_type: "p2sh_p2wpkh")
  end

  test "an address this codebase cannot derive has no script type" do
    [ "bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3", "not-an-address", "" ].each do |address|
      assert_nil Onchain::BitcoinPublicKey.script_type_of(address)
    end
  end

  test "recognizes private keys by their shape, checksum intact or not" do
    # Private keys of the same public test phrase.
    %w[
      xprv9xpXFhFpqdQK3TmytPBqXtGSwS3DLjojFhTGht8gwAAii8py5X6pxeBnQ6ehJiyJ6nDjWGJfZ95WxByFXVkDxHXrqu53WCRGypk2ttuqncb
      yprvAHwhK6RbpuS3dgCYHM5jc2ZvEKd7Bi61u9FVhYMpgMSuZS613T1xxQeKTffhrHY79hZ5PsskBjcc6C2V7DrnsMsNaGDaWev3GLRQRgV7hxF
      zprvAdG4iTXWBoARxkkzNpNh8r6Qag3irQB8PzEMkAFeTRXxHpbF9z4QgEvBRmfvqWvGp42t42nvgGpNgYSJA9iefm1yYNZKEm7z6qUWCroSQnE
      uprv91G7gZkzehuMVxDJTYE6tLivdF8e4rvzSu1LFfKw3b2Qx1Aj8vpoFnHdfUZ3hmi9jsvPifmZ24RTN2KhwB8BfMLTVqaBReibyaFFcTP1s9n
      Zprvtruncated
      wpkh([73c5da0a/84h/0h/0h]xprv9xpXFhFpqdQK3TmytPBqXtGSwS3DLjojFhTGht8gwAAii8py5X6pxeBnQ6ehJiyJ6nDjWGJfZ95WxByFXVkDxHXrqu53WCRGypk2ttuqncb/0/*)
      tprv8fVU32aAEuEPeH1WYx3LhXtSFZTRaFqjbFNPaJZ9R8fCVja44tSaUPZEKGpMK6McUDkWWMvRiVfKR3Wzei6AmLoTNYHMAZ9KtvVTLZZdhvA
      KyZpNDKnfs94vbrwhJneDi77V6jF64PWPF8x5cdJb8ifgg2DUc9d
    ].each { |value| assert Onchain::BitcoinPublicKey.private_key?(" #{value}\n"), value }

    [ ZPUB, XPUB, RECEIVE, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", "" ].each do |value|
      assert_not Onchain::BitcoinPublicKey.private_key?(value), value
    end
  end

  test "recognizes WIF of either network, mistyped or wrapped in something else" do
    # The private key 1, in every encoding of it.
    [
      "5HpHagT65TZzG1PH3CSu63k8DbpvD8s5ip4nEB3kEsreAnchuDf",
      "KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn",
      "91avARGdfge8E4tZfYLoxeJ5sGBdNJQH4kvjJoQFacbgwmaKkrx",
      "cMahea7zqjxrtgAbB7LSGbcQUr1uX1ojuat9jZodMN87JcbXMTcA"
    ].each do |wif|
      [ wif, " #{wif}\n", wif.chop, "#{wif}x", wif.sub(/.\z/, "0"), "p2wpkh:#{wif}", "wpkh(#{wif})", "key: \"#{wif}\"" ].each do |value|
        assert Onchain::BitcoinPublicKey.private_key?(value), value
      end
    end
  end

  # Addresses of other chains reach this check too, and some start like a WIF.
  test "an address or a public key is never taken for a private key" do
    [
      ZPUB, XPUB, RECEIVE, SECOND, CHANGE,
      "tpubD6NzVbkrYhZ4XgiXtGrdW5XDAPFCL9h7we1vwNCpn8tGbBcgfVYjXyhWo4E1xkh56hjod1RhGjxbaTLV3X4FyWuejifB9jusQ46QzG87VKp",
      "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",
      "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy",
      "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr",
      "cosmos1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
      "cosmos1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
      "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM",
      "5Q544fKrFoe6tsEbD7S8EmxGTJYAKtTVhAW5Q5pge4j1",
      "15oF4uVJwmo4TdGW7VfQxNLavjCXviqxT9S1MgbjMNHr6Sp5"
    ].each { |value| assert_not Onchain::BitcoinPublicKey.private_key?(value), value }
  end

  test "derives official BIP84 receive and change addresses" do
    key = Onchain::BitcoinPublicKey.new(ZPUB)
    assert_equal RECEIVE, key.address(0, 0)
    assert_equal SECOND, key.address(0, 1)
    assert_equal CHANGE, key.address(1, 0)
  end

  test "derives only receive and change branches at non-hardened indices" do
    # An account public key cannot derive hardened children; 0x80000000 would be one.
    key = Onchain::BitcoinPublicKey.new(ZPUB)
    [ [ 2, 0 ], [ 0, -1 ], [ 0, 0x80000000 ] ].each do |branch, index|
      assert_raises(Onchain::BitcoinPublicKey::InvalidKey) { key.address(branch, index) }
    end
  end

  test "derives the official BIP32 public child" do
    # Test vector 1: m/0H/1/2H and its non-hardened child m/0H/1/2H/2.
    key = Onchain::BitcoinPublicKey.new("xpub6D4BDPcP2GT577Vvch3R8wDkScZWzQzMMUm3PWbmWvVJrZwQY4VUNgqFJPMM3No2dFDFGTsxxpG5uJh7n7epu4trkrX7x7DogT5Uv6fcLW5")
    pub, chain_code = key.send(:derive, key.instance_variable_get(:@pub), key.instance_variable_get(:@chain_code), 2)
    assert_equal "02e8445082a72f29b75ca48748a914df60622a609cacfce8ed0e35804560741d29", pub.unpack1("H*")
    assert_equal "cfb71883f01676f587d023cc53a35bc7f88f724b1f8c2892ac1275ac822a3edd", chain_code.unpack1("H*")
  end

  test "xpub and zpub versions identify the same source" do
    plain = Onchain::BitcoinPublicKey.new(XPUB)
    assert_equal RECEIVE, plain.address(0, 0, script_type: "p2wpkh")
    assert_equal Onchain::BitcoinPublicKey.new(ZPUB).fingerprint, plain.fingerprint
  end

  test "fingerprints stay compatible with stored sources" do
    assert_equal "e9c5945c1ed8fb33780fc09caf0a79b8852eed6df035db9e04c340dacce83d97", Onchain::BitcoinPublicKey.new(ZPUB).fingerprint
  end

  test "rejects private keys unsupported networks and corrupt checksums" do
    %w[xprv123 zprv123 tpub123 seed].each do |value|
      assert_raises(Onchain::BitcoinPublicKey::InvalidKey) { Onchain::BitcoinPublicKey.new(value) }
    end
    assert_raises(Onchain::BitcoinPublicKey::InvalidKey) { Onchain::BitcoinPublicKey.new(ZPUB.chop + "a") }
  end

  test "accepts only hardened account-level keys" do
    # BIP32 test vectors: m/0H is the depth-1 node Electrum segwit seeds export;
    # the master key (depth 0), non-hardened m/0 and a BIP84 purpose node m/84H
    # (the m/0H vector with its child number changed) are not accounts.
    assert Onchain::BitcoinPublicKey.new("xpub68Gmy5EdvgibQVfPdqkBBCHxA5htiqg55crXYuXoQRKfDBFA1WEjWgP6LHhwBZeNK1VTsfTFUHCdrfp1bgwQ9xv5ski8PX9rL2dZXvgGDnw").address(0, 0, script_type: "p2wpkh").start_with?("bc1q")
    %w[
      xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8
      xpub69H7F5d8KSRgmmdJg2KhpAK8SR3DjMwAdkxj3ZuxV27CprR9LgpeyGmXUbC6wb7ERfvrnKZjXoUmmDznezpbZb7ap6r1D3tgFxHmwMkQTPH
      xpub68Gmy5Edvgif6b9GUbbRxC2yTApQqvEp4tR6sWsV64xvZHvxaK2K6L3RrMXA2Ez3ksVVecgaCJVKdJH2adWJWoXdBCzrHhqxf1B8KqK6TZG
    ].each do |value|
      error = assert_raises(Onchain::BitcoinPublicKey::InvalidKey) { Onchain::BitcoinPublicKey.new(value) }
      assert_equal "Use an account-level extended public key", error.message
    end
  end

  test "validates Bitcoin addresses using their checksum" do
    assert Onchain::BitcoinPublicKey.valid_address?(RECEIVE)
    refute Onchain::BitcoinPublicKey.valid_address?(RECEIVE.chop + "a")
    refute Onchain::BitcoinPublicKey.valid_address?("tb1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")
  end

  test "canonicalizes only uniformly cased Bech32 addresses" do
    assert_equal RECEIVE, Onchain::BitcoinPublicKey.canonical_address("  #{RECEIVE.upcase} ")
    # BIP173: mixed case is invalid, so it is kept for validation to reject, not repaired.
    mixed = RECEIVE.sub("bc1q", "bc1Q")
    assert_equal mixed, Onchain::BitcoinPublicKey.canonical_address(mixed)
    refute Onchain::BitcoinPublicKey.valid_address?(mixed)
  end

  test "accepts every standard mainnet output type and nothing else" do
    %w[
      1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2
      3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy
      bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3
      bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr
    ].each { |address| assert Onchain::BitcoinPublicKey.valid_address?(address), address }

    %w[
      1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN3
      mipcBbFg9gMiCh81Kj8tqqdgoZub1ZJRfn
      bc1qcr8te4kr609gcawutmrza0j4xv80jy8z3hvhsj
    ].each { |address| refute Onchain::BitcoinPublicKey.valid_address?(address), address }
  end
end

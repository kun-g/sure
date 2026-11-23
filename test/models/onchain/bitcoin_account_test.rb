# frozen_string_literal: true

require "test_helper"

class Onchain::BitcoinAccountTest < ActiveSupport::TestCase
  # The public BIP84 test vector account, never a user's key.
  ZPUB = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs"
  XPUB = "xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V"
  RECEIVE = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"
  CHANGE = "bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el"

  test "a key yields one account per script type it may stand for" do
    assert_equal %w[p2pkh p2sh_p2wpkh p2wpkh p2tr], Onchain::BitcoinAccount.for(XPUB).map(&:script_type)
    assert_equal %w[p2wpkh], Onchain::BitcoinAccount.for(ZPUB).map(&:script_type)
  end

  test "equivalent spellings of one account share a reference, script types do not" do
    references = Onchain::BitcoinAccount.for(XPUB).to_h { |account| [ account.script_type, account.reference ] }

    assert_equal 4, references.values.uniq.size
    assert_equal Onchain::BitcoinAccount.for(ZPUB).sole.reference, references["p2wpkh"]
    assert_match(/\Abip84:\h{32}\z/, references["p2wpkh"])
  end

  test "the reference and inspect reveal no key material" do
    account = Onchain::BitcoinAccount.for(ZPUB).sole

    assert_not_includes account.reference, ZPUB.last(20)
    assert_not_includes account.inspect, ZPUB
    assert_not_includes Onchain::BitcoinPublicKey.new(ZPUB).inspect, ZPUB
  end

  test "covers its own receive and change addresses, whatever their spelling" do
    account = Onchain::BitcoinAccount.for(ZPUB).sole

    assert_equal RECEIVE, account.first_address
    assert account.covers?(RECEIVE)
    assert account.covers?(CHANGE)
    assert account.covers?(" #{RECEIVE.upcase} ")
    assert account.covers?(account.address(1, Onchain::BitcoinAccount::LOOKUP_DEPTH - 1))
  end

  test "covers neither foreign addresses nor its own key under another script type" do
    account = Onchain::BitcoinAccount.for(ZPUB).sole
    legacy = Onchain::BitcoinAccount.for(XPUB).first

    assert_not account.covers?("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq")
    assert_not account.covers?(legacy.first_address)
    assert_not account.covers?("not-an-address")
    assert_not account.covers?("")
  end

  test "a key that cannot be used is a chain error, without the key in it" do
    [ "tpubD6NzVbkrYhZ4XgiXtGrdW5XDAPFCL9h7we1vwNCpn8tGbBcgfVYjXyhWo4E1xkh56hjod1RhGjxbaTLV3X4FyWuejifB9jusQ46QzG87VKp", ZPUB.chop + "a" ].each do |value|
      error = assert_raises(Onchain::Chains::Error) { Onchain::BitcoinAccount.for(value) }
      assert_not_includes error.message, value
    end
  end
end

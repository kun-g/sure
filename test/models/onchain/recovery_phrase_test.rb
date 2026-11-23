# frozen_string_literal: true

require "test_helper"

class Onchain::RecoveryPhraseTest < ActiveSupport::TestCase
  # Public BIP39 test vectors, never a user's phrase.
  WORDS = %w[
    letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd
    amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless
  ].freeze

  test "recognizes a phrase of every BIP39 length" do
    [ 12, 15, 18, 21, 24 ].each do |count|
      assert Onchain::RecoveryPhrase.match?(WORDS.first(count).join(" ")), count
    end
  end

  test "recognizes a phrase however it was copied" do
    words = WORDS.first(12)

    [
      "  #{words.join("  ")}\n",
      words.join("\n"),
      words.join("\t"),
      words.join("\u00a0"),
      words.join(","),
      words.join(", "),
      words.join(" ").upcase,
      words.map(&:capitalize).join(" "),
      words.each.with_index(1).map { |word, index| "#{index}. #{word}" }.join(" "),
      words.each.with_index(1).map { |word, index| "#{index}.#{word}" }.join("\n"),
      "\"#{words.join(" ")}\"",
      "seed: #{words.join(" ")}",
      words.join
    ].each { |value| assert Onchain::RecoveryPhrase.match?(value), value }
  end

  test "recognizes a phrase with words missing, left over or misspelled" do
    assert Onchain::RecoveryPhrase.match?(WORDS.first(11).join(" "))
    assert Onchain::RecoveryPhrase.match?([ *WORDS, "passphrase" ].join(" "))
    assert Onchain::RecoveryPhrase.match?([ "leter", *WORDS.first(11) ].join(" "))
  end

  test "recognizes phrases of the other BIP39 languages" do
    [
      "ábaco ábaco ábaco ábaco ábaco ábaco ábaco ábaco ábaco ábaco ábaco abierto",
      ([ "あいこくしん" ] * 11 + [ "あおぞら" ]).join("\u3000"),
      ([ "가격" ] * 12).join(" ").unicode_normalize(:nfkd),
      "的 的 的 的 的 的 的 的 的 的 的 在",
      "的的的的的的的的的的的在"
    ].each { |value| assert Onchain::RecoveryPhrase.match?(value), value }
  end

  test "an address, a public key or a short note is not a phrase" do
    [
      "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
      "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr",
      "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",
      BitcoinExplorerTestHelper::BIP84_ZPUB,
      "wpkh([73c5da0a/84h/0h/0h]#{BitcoinExplorerTestHelper::BIP84_XPUB}/0/*)",
      "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
      "cosmos1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
      "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM",
      # What Base58 allows, however unlikely a key made of letters alone is.
      "a" * 44,
      "https://mempool.space/address/bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
      "definitely-not-an-address",
      "my old wallet",
      "",
      nil
    ].each { |value| assert_not Onchain::RecoveryPhrase.match?(value), value.inspect }
  end
end

# frozen_string_literal: true

require "test_helper"

class Onchain::Base58Test < ActiveSupport::TestCase
  test "decodes to the bytes the string stands for" do
    # "2g" is 1 * 58 + 39 = 97 = 0x61
    assert_equal "a".b, Onchain::Base58.decode("2g")
  end

  test "each leading 1 is a leading zero byte" do
    assert_equal "\x00\x00".b, Onchain::Base58.decode("11")
    assert_equal "\x00".b, Onchain::Base58.decode("1")
    assert_equal "".b, Onchain::Base58.decode("")
  end

  test "a Solana key is 32 bytes and a Bitcoin or TRON address is 25" do
    assert_equal 32, Onchain::Base58.decode("9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM").bytesize
    assert_equal 25, Onchain::Base58.decode("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa").bytesize
    assert_equal 25, Onchain::Base58.decode("TJRabPrwbZy45sbavfcjinPJC18kjpRTv8").bytesize
  end

  test "a character outside the alphabet decodes to nil" do
    assert_nil Onchain::Base58.decode("0OIl")
  end

  test "agrees with the checksummed decoder on a real address" do
    address = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"

    assert_equal Onchain::BitcoinPublicKey.base58check_decode(address), Onchain::Base58.decode(address)[0...-4]
  end
end

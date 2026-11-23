# frozen_string_literal: true

# Plain Base58 decoding, no checksum. The length of what a string decodes to is
# what tells address families apart when their text shapes overlap: a Solana key
# is 32 bytes, while a Bitcoin or TRON address is 25 with a checksum on top.
module Onchain::Base58
  ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  # @return [String, nil] the decoded bytes, nil when a character is outside the alphabet
  def self.decode(text)
    number = 0
    text.each_char do |char|
      digit = ALPHABET.index(char)
      return nil if digit.nil?

      number = number * 58 + digit
    end

    hex = number.zero? ? "" : number.to_s(16)
    # Each leading "1" stands for one leading zero byte.
    (("\x00" * text[/\A1*/].size) + [ hex.rjust(hex.size + hex.size % 2, "0") ].pack("H*")).b
  end
end

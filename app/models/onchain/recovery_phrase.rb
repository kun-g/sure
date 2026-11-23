# frozen_string_literal: true

module Onchain
  # Whether an input reads like a wallet's recovery phrase (BIP39 and the like).
  #
  # Told by its shape, without a word list. A list would let a misspelled word, a
  # phrase in another language or one from another scheme through, and those are
  # secrets too. Nothing Sure accepts contains words separated by spaces, so being
  # this broad costs a sentence pasted by mistake a different error message and
  # never turns away an address or a public key.
  module RecoveryPhrase
    # Half of the shortest phrase: an incomplete copy still gives most of it away.
    MIN_WORDS = 6

    # Chinese phrases have one character per word and may be written without spaces.
    SEPARATOR = /[[:space:],;]+|(?<=\p{Han})(?=\p{Han})/

    # A word of any script, with what a copied list leaves around it: "1.", quotes.
    WORD = /\A[^\p{L}\p{M}]*[\p{L}\p{M}]+[^\p{L}\p{M}]*\z/

    # A phrase that lost its spaces. The longest address that could consist of
    # letters alone has 44.
    JOINED_WORDS = /\A\s*(?:[a-z]{45,}|[A-Z]{45,})\s*\z/

    def self.match?(value)
      text = value.to_s
      text.match?(JOINED_WORDS) || text.split(SEPARATOR).count { |token| token.match?(WORD) } >= MIN_WORDS
    end
  end
end

# frozen_string_literal: true

# How far a sync looks for the addresses of a wallet given as an account key.
#
# Nothing lists the addresses such a wallet has used, so they are found by asking
# about derived ones in order until `gap_limit` of them in a row are unused — the
# convention wallets follow when they restore from a seed. Each address is one
# request against a shared endpoint, so the walk has an end of its own: past it
# the wallet is read incompletely and says so.
module Onchain
  module AddressScanBudget
    # BIP44's, and the default of every wallet that lets it be changed.
    DEFAULT_GAP_LIMIT = 20
    MAX_GAP_LIMIT = 200

    DEFAULT_ADDRESSES = 400
    MAX_ADDRESSES = 5_000

    # Receiving and change.
    BRANCHES = 2

    class << self
      def gap_limit
        positive_env("ONCHAIN_GAP_LIMIT", default: DEFAULT_GAP_LIMIT, max: MAX_GAP_LIMIT)
      end

      # Never fewer than it takes to find both branches unused: below that even an
      # empty wallet would count as incompletely read.
      def addresses
        configured = positive_env("ONCHAIN_MAX_ADDRESSES_PER_WALLET", default: DEFAULT_ADDRESSES, max: MAX_ADDRESSES)

        [ configured, BRANCHES * gap_limit ].max
      end

      # Onchain::HistoryBudget bounds the history of one address; a wallet of
      # hundreds needs a bound on all of them together, which is one page for each
      # address the scan may look at.
      def history_pages
        addresses
      end

      private
        def positive_env(name, default:, max:)
          configured = ENV[name].to_i
          configured.positive? ? configured.clamp(1, max) : default
        end
    end
  end
end

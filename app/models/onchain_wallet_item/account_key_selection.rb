# frozen_string_literal: true

# Settles which account an account key stands for.
#
# A key that states its script type settles it by itself. One that does not is
# settled by its owner, either by choosing the script type or by giving an address
# of the wallet, which only one of them derives. Nothing else decides: the wrong
# type derives addresses that are valid and empty, so a guess would sync without
# an error and report a wallet that is not there.
class OnchainWalletItem::AccountKeySelection
  attr_reader :script_type, :known_address

  def initialize(adapter, key, script_type: nil, known_address: nil)
    @adapter = adapter
    @key = key
    @script_type = script_type.presence
    @known_address = known_address.to_s.strip.presence
  end

  # @raise [Onchain::Chains::Error] when the key cannot be used
  def candidates
    @candidates ||= adapter.accounts_for(key)
  end

  # The only account left standing, or nil.
  def account
    remaining.sole if remaining.one?
  end

  # Why what the owner said fits none of the candidates, as a translation key.
  def error
    return nil if remaining.any?

    known_address ? :known_address_mismatch : :script_type_unsupported
  end

  private
    attr_reader :adapter, :key

    # Everything said has to agree: an address that contradicts the chosen type
    # means one of the two is wrong, and not which.
    def remaining
      @remaining ||= candidates
        .select { |account| script_type.nil? || account.script_type == script_type }
        .select { |account| known_address.nil? || account.covers?(known_address) }
    end
end

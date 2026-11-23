# frozen_string_literal: true

module Family::OnchainWalletConnectable
  extend ActiveSupport::Concern

  included do
    has_many :onchain_wallet_items, dependent: :destroy
  end

  def can_connect_onchain_wallet?
    true
  end

  # A family needs only one self-custody connection; every address it tracks
  # hangs off the same item.
  def onchain_wallet_item
    onchain_wallet_items.active.ordered.last
  end

  def onchain_wallet_item!
    onchain_wallet_item || create_onchain_wallet_item!
  end

  def create_onchain_wallet_item!
    onchain_wallet_items.create!(name: I18n.t("onchain.institution_name")).tap do |item|
      item.set_onchain_institution_defaults!
    end
  end

  def has_onchain_wallets?
    onchain_wallet_items.active.joins(:onchain_wallet_accounts).exists?
  end

  # True when an address is already tracked on this chain anywhere in the
  # family, which is what makes re-linking it a duplicate. Tracked means linked,
  # not merely present: a row whose account is gone syncs nothing and displays
  # nowhere, so counting it here would refuse the address with nothing to show
  # for it.
  def onchain_address_linked?(chain, address)
    linked_onchain_accounts(chain).for_wallet(chain, address).exists?
  end

  # True when an address belongs to an account the family already tracks by its
  # key: tracking it as well would count its coins twice.
  def onchain_address_covered?(chain, address)
    linked_onchain_accounts(chain).with_account_key.any? do |row|
      row.key_account.covers?(address)
    rescue Onchain::Chains::Error
      # A key that cannot be read covers nothing; its own sync reports it.
      false
    end
  end

  # The reverse: addresses tracked on their own that an account would count again.
  def onchain_addresses_inside(chain, key_account)
    linked_onchain_accounts(chain).without_account_key.distinct.pluck(:wallet_address)
      .select { |address| key_account.covers?(address) }
  end

  private
    def linked_onchain_accounts(chain)
      OnchainWalletAccount.where(onchain_wallet_item: onchain_wallet_items.active, chain: chain).linked
    end
end

# frozen_string_literal: true

class AddExtendedPublicKeyToOnchainWalletAccounts < ActiveRecord::Migration[8.1]
  def change
    # Set on the rows of a wallet linked by its account key, whose wallet_address
    # holds a reference derived from the key rather than an address. Encrypted by
    # the model: whoever reads the key can list every address of the wallet.
    add_column :onchain_wallet_accounts, :extended_public_key, :text
    add_column :onchain_wallet_accounts, :script_type, :string

    # A key means nothing without the script type it was linked as.
    add_check_constraint :onchain_wallet_accounts,
                         "(extended_public_key IS NULL) = (script_type IS NULL)",
                         name: "chk_onchain_wallet_accounts_key_has_script_type"
  end
end

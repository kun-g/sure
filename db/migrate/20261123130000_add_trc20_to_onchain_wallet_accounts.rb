class AddTrc20ToOnchainWalletAccounts < ActiveRecord::Migration[8.1]
  # A token kind is only usable once it has its own partial unique index (see
  # Onchain::Chains::INDEXED_TOKEN_KINDS) and the known-kind check admits it.
  def change
    remove_check_constraint :onchain_wallet_accounts,
                            "asset_kind IN ('native', 'erc20', 'spl')",
                            name: "chk_onchain_wallet_accounts_known_asset_kind"
    add_check_constraint :onchain_wallet_accounts,
                         "asset_kind IN ('native', 'erc20', 'spl', 'trc20')",
                         name: "chk_onchain_wallet_accounts_known_asset_kind"

    add_index :onchain_wallet_accounts,
              [ :onchain_wallet_item_id, :chain, :wallet_address, :contract_address ],
              unique: true,
              where: "asset_kind = 'trc20'",
              name: "index_onchain_wallet_accounts_unique_trc20"
  end
end

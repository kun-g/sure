# frozen_string_literal: true

# Self-custody wallet connections. Chain-agnostic throughout: a chain is a
# registry key that arrives as a parameter, gets validated against the registry,
# and is never branched on.
class OnchainWalletItemsController < ApplicationController
  before_action :require_admin!
  before_action :set_onchain_wallet_item,
                only: %i[update destroy sync manage review_tokens update_tokens
                         disconnect_wallet disconnect_asset]
  before_action :set_wallet, only: %i[review_tokens update_tokens disconnect_wallet]
  before_action :refuse_private_key, only: %i[preview_wallet link_wallet]

  def update
    if @onchain_wallet_item.update(onchain_wallet_item_params)
      render_provider_panel("onchain_wallet", notice: t(".success"))
    else
      render_provider_panel("onchain_wallet", alert: @onchain_wallet_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @onchain_wallet_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    @onchain_wallet_item.sync_later unless @onchain_wallet_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to settings_providers_path }
      format.json { head :ok }
    end
  end

  # Turns the "no crypto prices configured" warning into one click. Without a
  # crypto-capable market data provider every on-chain holding is valued at zero,
  # which reads as a broken sync; making the user go and find the setting is how
  # that becomes a support ticket instead of a fix.
  def enable_crypto_prices
    unless self_hosted?
      return redirect_back_or_to settings_providers_path, alert: t(".not_self_hosted")
    end

    Onchain::SecurityResolver.enable_price_provider!

    redirect_back_or_to settings_providers_path, notice: t(".success")
  end

  # Step 1: paste an address, or the account key of a wallet that has many.
  def new_wallet
    @address = nil
  end

  # Step 2: work out the chain if it wasn't given, then show what is there.
  def preview_wallet
    @address = normalized_address
    return render_new_wallet(t(".errors.address_required")) if @address.blank?

    @chain = requested_chain
    if @chain.blank? && account_key_chain.nil?
      detection = OnchainWalletItem::ChainDetector.new(preview_item, @address).detect
      return render_new_wallet(t(".errors.unrecognized_address")) if detection.unrecognized?

      if detection.ambiguous?
        @detection = detection
        return render :choose_chain
      end

      @chain = detection.chain
    end

    snapshot = read_new_wallet
    return if performed?

    @assets_truncated = snapshot.assets_truncated?
    @review = OnchainWalletItem::TokenReview.new(snapshot: snapshot)
    render :token_review
  end

  # Step 3: track the assets that were ticked.
  def link_wallet
    @address = normalized_address
    @chain = requested_chain
    return render_new_wallet(t(".errors.unrecognized_address")) if @chain.blank? || @address.blank?

    snapshot = read_new_wallet
    return if performed?

    # The connection is created only now. Reading the address needs none, so a
    # failed read must not leave an empty one behind — the same reason previewing
    # uses an unsaved one.
    result = OnchainWalletItem::WalletLinker
      .new(Current.family.onchain_wallet_item!, chain: @chain, address: wallet_address, key_account: @key_account)
      .link(snapshot: snapshot, selected_keys: params[:assets])

    unless result.success?
      @assets_truncated = snapshot.assets_truncated?
      @review = OnchainWalletItem::TokenReview.new(snapshot: snapshot)
      # Telling someone who ticked three assets to "pick at least one" sends them
      # back to tick the same three.
      flash.now[:alert] = if result.errors.any?
        t(".errors.none_tracked", assets: result.errors.to_sentence)
      else
        t(".errors.nothing_selected")
      end
      return render :token_review, status: :unprocessable_entity
    end

    flash[:alert] = t(".errors.some_failed", assets: result.errors.to_sentence) if result.errors.any?
    redirect_to accounts_path, notice: t(".success", count: result.created), status: :see_other
  end

  # Everything a linked wallet can have done to it, in one place.
  def manage
  end

  # The token screen again, with the address left alone. Without this the only
  # way to stop tracking one asset would be to change the address.
  def review_tokens
    snapshot = read_tracked_wallet
    return redirect_to_manage(alert: @provider_error) if snapshot.nil?

    @assets_truncated = snapshot.assets_truncated?
    @review = review_for(snapshot)
  end

  def update_tokens
    snapshot = read_tracked_wallet
    return redirect_to_manage(alert: @provider_error) if snapshot.nil?

    result = wallet_linker.revise(snapshot: snapshot, selected_keys: params[:assets])

    unless result.changed?
      @assets_truncated = snapshot.assets_truncated?
      @review = review_for(snapshot)
      flash.now[:alert] = if result.errors.any?
        t(".errors.none_tracked", assets: result.errors.to_sentence)
      else
        t(".errors.no_changes")
      end
      return render :review_tokens, status: :unprocessable_entity
    end

    flash[:alert] = t(".errors.some_failed", assets: result.errors.to_sentence) if result.errors.any?
    redirect_to_manage(notice: t(".success", created: result.created, removed: result.removed))
  end



  def disconnect_wallet
    removed = @onchain_wallet_item.disconnect_wallet!(chain: @chain, address: @address)

    redirect_to_manage(notice: t(".success", count: removed))
  end

  def disconnect_asset
    onchain_account = @onchain_wallet_item.onchain_wallet_accounts.find(params[:onchain_wallet_account_id])
    onchain_account.destroy!

    redirect_to_manage(notice: t(".success", symbol: onchain_account.symbol))
  end

  private
    def set_onchain_wallet_item
      @onchain_wallet_item = Current.family.onchain_wallet_items.find(params[:id])
    end

    # A wallet is a (chain, address) couple, and only one this connection already
    # tracks: every management action is scoped through the family's own item.
    def set_wallet
      @chain = requested_chain
      @address = normalized_address

      return if @chain.present? && @onchain_wallet_item.tracks_address?(@chain, @address)

      redirect_to_manage(alert: t("onchain_wallet_items.errors.wallet_not_found"))
    end

    def wallet_linker
      OnchainWalletItem::WalletLinker.new(@onchain_wallet_item, chain: @chain, address: @address, key_account: @key_account)
    end

    def review_for(snapshot)
      OnchainWalletItem::TokenReview.new(
        snapshot: snapshot,
        tracked_accounts: @onchain_wallet_item.accounts_for_wallet(@chain, @address).to_a
      )
    end

    def redirect_to_manage(flash_message)
      redirect_to manage_onchain_wallet_item_path(@onchain_wallet_item), **flash_message, status: :see_other
    end


    def onchain_wallet_item_params
      permitted = params.require(:onchain_wallet_item).permit(:sync_start_date, :etherscan_api_key)
      # Blank means "leave the stored key alone", not "clear it".
      permitted.delete(:etherscan_api_key) if permitted[:etherscan_api_key].blank?
      permitted
    end

    # Reading an address needs no saved connection, so previewing one never
    # leaves an empty item behind for an abandoned flow.
    def preview_item
      @preview_item ||= Current.family.onchain_wallet_item ||
        Current.family.onchain_wallet_items.new(name: I18n.t("onchain.institution_name"))
    end

    def normalized_address
      params[:address].to_s.strip
    end

    # A secret is turned away before anything parses, stores or shows it again.
    def refuse_private_key
      return if [ params[:address], params[:known_address] ].none? { |value| Onchain::Chains.private_key?(value) }

      @address = nil
      render_new_wallet(t("onchain_wallet_items.errors.private_key"))
    end

    # The chain whose account key was pasted, or nil when it was an address.
    def account_key_chain
      Onchain::Chains.accepting_account_key(@address).find { |definition| @chain.blank? || definition.key == @chain }
    end

    # What a wallet is stored under: its address, or the reference of an account.
    def wallet_address
      @key_account&.reference || @address
    end

    # What can be tracked at the address or account key the user gave. Renders and
    # returns nil when it cannot be tracked at all.
    def read_new_wallet
      definition = account_key_chain
      return read_new_address if definition.nil?

      @chain = definition.key
      @key_account = resolve_key_account(definition)
      definition.adapter.account_preview if @key_account
    end

    def read_new_address
      # Only now can the address be put in its canonical form: what counts as the
      # same address is a per-chain question, and the duplicate check has to run on
      # the canonical form or two spellings become two wallets.
      @address = Onchain::Chains.canonical_address(@chain, @address)

      if Current.family.onchain_address_linked?(@chain, @address)
        render_new_wallet(t("onchain_wallet_items.errors.already_linked"))
      elsif Current.family.onchain_address_covered?(@chain, @address)
        render_new_wallet(t("onchain_wallet_items.errors.address_in_tracked_account"))
      elsif (snapshot = fetch_snapshot(@chain, @address)).nil?
        render_new_wallet(@provider_error)
      end

      snapshot
    end

    def resolve_key_account(definition)
      @selection = OnchainWalletItem::AccountKeySelection.new(
        definition.adapter, @address, script_type: params[:script_type], known_address: params[:known_address]
      )
      account = @selection.account

      if account.nil?
        # Asking is a step of the flow; not having an answer by now is a mistake.
        render :choose_script_type, status: @selection.error || action_name == "link_wallet" ? :unprocessable_entity : :ok
      elsif Current.family.onchain_address_linked?(@chain, account.reference)
        render_new_wallet(t("onchain_wallet_items.errors.already_linked"))
      elsif (addresses = Current.family.onchain_addresses_inside(@chain, account)).any?
        render_new_wallet(t("onchain_wallet_items.errors.account_contains_tracked_address", addresses: addresses.to_sentence))
      else
        return account
      end

      nil
    rescue Onchain::Chains::Error
      render_new_wallet(t("onchain_wallet_items.errors.invalid_account_key"))
      nil
    end

    # An account is not read again to revise what is tracked in it: that is known
    # without asking, and asking takes too long for a page.
    def read_tracked_wallet
      @key_account = @onchain_wallet_item.key_account_for(@chain, @address)
      return Onchain::Chains.adapter_for(@chain).account_preview if @key_account

      fetch_snapshot(@chain, @address)
    rescue Onchain::Chains::Error
      @provider_error = t("onchain_wallet_items.errors.invalid_account_key")
      nil
    end

    # Only a chain the registry knows can get through.
    def requested_chain
      chain = params[:chain].to_s.strip
      Onchain::Chains.exists?(chain) ? chain : nil
    end

    # Expected data-source failures become a localized message. Anything else is
    # a bug: the user gets a generic message and the details go to the debug log,
    # never into the response.
    def fetch_snapshot(chain, address)
      OnchainWalletItem::Importer.new(preview_item).fetch_snapshot(chain: chain, address: address)
    rescue Onchain::Chains::RateLimitedError
      @provider_error = t("onchain_wallet_items.errors.rate_limited")
      nil
    rescue Onchain::Chains::UnreachableError
      @provider_error = t("onchain_wallet_items.errors.chain_unreachable")
      nil
    rescue Onchain::Chains::Error
      @provider_error = t("onchain_wallet_items.errors.unrecognized_address")
      nil
    rescue StandardError => e
      capture_unexpected(e, chain: chain)
      @provider_error = t("onchain_wallet_items.errors.unexpected")
      nil
    end

    def capture_unexpected(error, chain:)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Unexpected on-chain wallet failure: #{error.class}",
        source: self.class.name,
        provider_key: "onchain_wallet",
        family: Current.family,
        metadata: { chain: chain, error: error.message }
      )
    end

    def render_new_wallet(error_message, status: :unprocessable_entity)
      @error_message = error_message
      render :new_wallet, status: status
    end
end

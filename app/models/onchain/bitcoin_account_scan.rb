# frozen_string_literal: true

# Finds the addresses an account has used, and what they hold, by walking its
# receiving and change branches until a full gap of unused addresses on each.
class Onchain::BitcoinAccountScan
  # { address => number of transactions touching it }
  attr_reader :used

  # What the wallet holds, in satoshis, confirmed and mempool together.
  attr_reader :sats

  # Every address looked at. Unused ones belong to the wallet all the same: the
  # next change output goes to one of them.
  attr_reader :addresses

  def initialize(account, provider:)
    @account = account
    @provider = provider
    @used = {}
    @sats = 0
    @addresses = Set.new
    @truncated = false
  end

  # One address of each branch at a time, so that a scan cut short by its budget
  # has read as much change as it has receiving addresses.
  def perform
    gaps = Onchain::BitcoinAccount::BRANCHES.index_with(0)

    (0..).each do |index|
      open = gaps.keys.select { |branch| gaps[branch] < gap_limit }
      break if open.empty?

      open.each do |branch|
        if addresses.size >= budget
          @truncated = true
          return self
        end

        gaps[branch] = read(account.address(branch, index)) ? 0 : gaps[branch] + 1
      end
    end

    self
  end

  # True when the walk stopped on its budget rather than on a gap, in which case
  # there may be coins it never looked at.
  def truncated?
    @truncated
  end

  private
    attr_reader :account, :provider

    def gap_limit
      @gap_limit ||= Onchain::AddressScanBudget.gap_limit
    end

    def budget
      @budget ||= Onchain::AddressScanBudget.addresses
    end

    # @return [Boolean] whether the address was ever used
    def read(address)
      summary = provider.get_address(address)
      addresses << address

      transactions = figure(summary, "tx_count")
      return false if transactions.zero?

      used[address] = transactions
      @sats += figure(summary, "funded_txo_sum") - figure(summary, "spent_txo_sum")
      true
    end

    # Strict, unlike a single address: a missing count read as zero would pass for
    # an unused address, end the walk early and report a wallet with less in it.
    def figure(summary, name)
      %w[chain_stats mempool_stats].sum { |scope| Integer(summary.fetch(scope).fetch(name)) }
    rescue KeyError, TypeError, ArgumentError, NoMethodError
      raise Onchain::Chains::UnreachableError, "The explorer returned an unreadable address summary"
    end
end

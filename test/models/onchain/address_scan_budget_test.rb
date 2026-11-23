# frozen_string_literal: true

require "test_helper"

class Onchain::AddressScanBudgetTest < ActiveSupport::TestCase
  ENV_KEYS = %w[ONCHAIN_GAP_LIMIT ONCHAIN_MAX_ADDRESSES_PER_WALLET].freeze

  setup do
    @previous = ENV_KEYS.index_with { |key| ENV[key] }
    ENV_KEYS.each { |key| ENV.delete(key) }
  end

  teardown do
    @previous.each { |key, value| ENV[key] = value }
  end

  test "defaults to the gap limit wallets use and a bounded scan" do
    assert_equal 20, Onchain::AddressScanBudget.gap_limit
    assert_equal 400, Onchain::AddressScanBudget.addresses
  end

  test "a self-hoster can raise both, within bounds" do
    ENV["ONCHAIN_GAP_LIMIT"] = "50"
    ENV["ONCHAIN_MAX_ADDRESSES_PER_WALLET"] = "1000"
    assert_equal 50, Onchain::AddressScanBudget.gap_limit
    assert_equal 1000, Onchain::AddressScanBudget.addresses

    ENV["ONCHAIN_GAP_LIMIT"] = "100000"
    ENV["ONCHAIN_MAX_ADDRESSES_PER_WALLET"] = "100000"
    assert_equal Onchain::AddressScanBudget::MAX_GAP_LIMIT, Onchain::AddressScanBudget.gap_limit
    assert_equal Onchain::AddressScanBudget::MAX_ADDRESSES, Onchain::AddressScanBudget.addresses
  end

  test "nonsense falls back to the defaults" do
    ENV["ONCHAIN_GAP_LIMIT"] = "-1"
    ENV["ONCHAIN_MAX_ADDRESSES_PER_WALLET"] = "lots"

    assert_equal 20, Onchain::AddressScanBudget.gap_limit
    assert_equal 400, Onchain::AddressScanBudget.addresses
  end

  test "the scan is never too short to prove that both branches are unused" do
    ENV["ONCHAIN_MAX_ADDRESSES_PER_WALLET"] = "1"

    assert_equal 40, Onchain::AddressScanBudget.addresses
  end
end

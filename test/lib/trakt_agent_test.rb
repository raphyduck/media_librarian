# frozen_string_literal: true

require 'test_helper'
require 'date'
require 'net/http'
require 'tmpdir'
require 'fileutils'
require_relative '../../lib/trakt_agent'

class TraktAgentTest < Minitest::Test
  def setup
    super
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    @calendar_response = Net::HTTPOK.new('1.1', '200', 'OK')
    @calendar_response.body = '[]'
    @calendar_response.instance_variable_set(:@read, true)
  end

  def teardown
    MediaLibrarian.application = nil
    @environment&.cleanup
    super
  end

  def test_https_fallback_uses_ssl_context_and_crl_checks
    stores = []
    @environment.container.reload_config!('trakt' => { 'client_id' => 'client', 'access_token' => 'token' })

    captured_context = nil
    Net::HTTP.stub :start, http_stub(captured_context_proc: ->(ctx) { captured_context = ctx }) do
      OpenSSL::X509::Store.stub :new, -> { build_instrumented_store(stores) } do
        assert_equal [], TraktAgent.fetch_calendar_from_http(:shows, Date.new(2024, 1, 1), 1)
      end
    end

    refute_nil captured_context
    assert_equal OpenSSL::SSL::VERIFY_PEER, captured_context.verify_mode
    refute_empty stores
    store = stores.first
    assert store.default_paths_set
    assert_equal OpenSSL::X509::V_FLAG_CRL_CHECK_ALL, store.flag_value
  end

  def test_allows_disabling_crl_checks_with_custom_ca_path
    ca_path = Dir.mktmpdir('trakt-ca')
    stores = []
    @environment.container.reload_config!('trakt' => {
      'client_id' => 'client',
      'ca_path' => ca_path,
      'disable_crl_checks' => true
    })

    Net::HTTP.stub :start, http_stub do
      OpenSSL::X509::Store.stub :new, -> { build_instrumented_store(stores) } do
        assert_equal [], TraktAgent.fetch_calendar_from_http(:movies, Date.new(2024, 1, 1), 3)
      end
    end

    refute_empty stores
    store = stores.first
    assert_equal [ca_path], store.added_paths
    assert_nil store.flag_value
  ensure
    FileUtils.remove_entry(ca_path) if ca_path && Dir.exist?(ca_path)
  end

  private

  HttpDouble = Struct.new(:use_ssl, :ssl_context, :response) do
    def request(_request)
      response
    end
  end

  class InstrumentedStore < OpenSSL::X509::Store
    attr_reader :added_paths, :flag_value
    attr_accessor :default_paths_set

    def initialize
      super
      @added_paths = []
      @default_paths_set = false
      @flag_value = nil
    end

    def add_path(path)
      @added_paths << path
      super
    end

    def set_default_paths
      self.default_paths_set = true
      super
    end

    def flags=(value)
      @flag_value = value
      super
    end
  end

  def http_stub(captured_context_proc: nil)
    lambda do |host, port, **options, &block|
      captured_context_proc&.call(options[:ssl_context])
      http = HttpDouble.new(options[:use_ssl], options[:ssl_context], @calendar_response)
      block.call(http)
    end
  end

  def build_instrumented_store(collection)
    InstrumentedStore.allocate.tap do |store|
      store.send(:initialize)
      collection << store
    end
  end
end

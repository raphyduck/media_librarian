# frozen_string_literal: true

require 'json'
require 'ostruct'
require 'fileutils'
require 'tmpdir'

require_relative 'test_helper'
require_relative '../app/daemon'
require_relative '../lib/watchlist_store'
require_relative '../lib/storage/db'

class DaemonWatchlistApiTest < Minitest::Test
  def setup
    @environment = build_stubbed_environment
    ensure_db_accessor(@environment.application)
    @environment.application.db = Storage::Db.new(File.join(@environment.root_path, 'librarian.db'))
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
  end

  def teardown
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def test_post_requires_imdb_id
    response = FakeResponse.new
    request = OpenStruct.new(request_method: 'POST', body: { title: 'Missing id' }.to_json, query: {}, path: '/watchlist')

    Daemon.send(:handle_watchlist_request, request, response)

    assert_equal 422, response.status
  end

  def test_crud_relies_on_imdb_id
    post_response = FakeResponse.new
    post_request = OpenStruct.new(
      request_method: 'POST',
      body: { imdb_id: 'tt7777', title: 'Example', metadata: { ids: { tmdb: '777' } } }.to_json,
      query: {},
      path: '/watchlist'
    )

    Daemon.send(:handle_watchlist_request, post_request, post_response)

    assert_equal 200, post_response.status
    entries = WatchlistStore.fetch
    assert_equal ['tt7777'], entries.map { |row| row[:imdb_id] }

    delete_response = FakeResponse.new
    delete_request = OpenStruct.new(request_method: 'DELETE', body: { imdb_id: 'tt7777' }.to_json, query: {}, path: '/watchlist')
    Daemon.send(:handle_watchlist_request, delete_request, delete_response)

    assert_empty WatchlistStore.fetch
  end

  def test_rejects_external_id_instead_of_imdb
    response = FakeResponse.new
    request = OpenStruct.new(
      request_method: 'POST',
      body: { external_id: 'legacy-1', title: 'Legacy' }.to_json,
      query: {},
      path: '/watchlist'
    )

    Daemon.send(:handle_watchlist_request, request, response)

    assert_equal 422, response.status
    assert_empty WatchlistStore.fetch
  end

  private

  def ensure_db_accessor(application)
    return if application.respond_to?(:db)

    application.singleton_class.class_eval { attr_accessor :db }
  end

  class FakeResponse
    attr_accessor :status, :body

    def initialize
      @headers = {}
      @status = nil
      @body = nil
    end

    def []=(key, value)
      @headers[key] = value
    end
  end
end

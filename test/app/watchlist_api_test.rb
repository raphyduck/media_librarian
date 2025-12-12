# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'ostruct'
require_relative '../../app/daemon'
require_relative '../../lib/watchlist_store'
require_relative '../../lib/storage/db'

class WatchlistApiTest < Minitest::Test
  def setup
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    attach_db(Storage::Db.new(File.join(@environment.root_path, 'librarian.db')))
    Daemon.configure(app: @environment.application)
  end

  def teardown
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def test_post_requires_imdb_id
    response = FakeResponse.new
    request = OpenStruct.new(request_method: 'POST', body: { title: 'Missing id' }.to_json)

    Daemon.send(:handle_watchlist_request, request, response)

    assert_equal 422, response.status
    assert_equal({ 'error' => 'missing_id' }, JSON.parse(response.body))
  end

  def test_crud_operates_on_imdb_id_only
    response = FakeResponse.new
    request = OpenStruct.new(
      request_method: 'POST',
      body: { title: 'With id', imdb_id: 'tt0123', metadata: { ids: { tmdb: '42' } } }.to_json
    )

    Daemon.send(:handle_watchlist_request, request, response)
    assert_equal 200, response.status, response.body

    rows = WatchlistStore.fetch
    refute_empty rows
    row = rows.first
    assert_equal 'tt0123', row[:imdb_id]
    assert_equal 'tt0123', row[:external_id]
    ids = row[:metadata][:ids] || row[:metadata]['ids']
    assert_equal 'tt0123', ids[:imdb] || ids['imdb']

    delete_response = FakeResponse.new
    delete_request = OpenStruct.new(request_method: 'DELETE', body: { imdb_id: 'tt0123' }.to_json, query: {})
    Daemon.send(:handle_watchlist_request, delete_request, delete_response)

    assert_equal 200, delete_response.status
    assert_equal 0, WatchlistStore.fetch.length
  end

  private

  def attach_db(db)
    app = @environment.application
    app.singleton_class.class_eval { attr_accessor :db }
    app.db = db
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

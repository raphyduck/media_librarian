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
    attach_db(Storage::Db.new(File.join(@environment.root_path, 'librarian.db')))
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

  def test_get_decorates_entries_with_sorted_pending_torrents_and_orphans
    app = @environment.application
    app.db.insert_row('calendar_entries', {
      source: 'tmdb', external_id: '42', imdb_id: 'tt0042',
      title: 'Backrooms', media_type: 'movies', release_date: '2026-02-01'
    })
    WatchlistStore.upsert([{ imdb_id: 'tt0042', title: 'Backrooms', type: 'movies' }])

    ident = 'movieBackrooms (2026)2026'
    app.db.insert_row('torrents', {
      name: 'Backrooms.2026.1080p.WEBRip', identifier: ident, status: 1,
      tattributes: { tracker: 'c411', size: 3 * 1024**3,
                     timeframe_quality: 600, timeframe_tracker: 0, timeframe_size: 0 }
    })
    app.db.insert_row('torrents', {
      name: 'Backrooms.2026.2160p.WEB', identifier: ident, status: 2,
      tattributes: { tracker: 'c411', size: 10 * 1024**3,
                     timeframe_quality: 0, timeframe_tracker: 0, timeframe_size: 0 }
    })
    app.db.insert_row('torrents', {
      name: 'Some.Show.S01E01.1080p', identifier: 'showSome Show1x1', status: 1,
      tattributes: { tracker: 'torr9', size: 2 * 1024**3,
                     timeframe_quality: 0, timeframe_tracker: 0, timeframe_size: 0 }
    })

    response = FakeResponse.new
    request = OpenStruct.new(request_method: 'GET', query: {}, path: '/watchlist')
    Daemon.send(:handle_watchlist_request, request, response)

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    entries = payload['entries']
    assert_equal 1, entries.length
    torrents = entries.first['torrents']
    assert_equal %w[Backrooms.2026.2160p.WEB Backrooms.2026.1080p.WEBRip], torrents.map { |t| t['name'] },
                 'torrents must be ranked best quality (smallest timeframe) first'
    assert_equal [2, 1], torrents.map { |t| t['status'] }

    orphans = payload['orphans']
    assert_equal 1, orphans.length
    assert_equal 'showSome Show1x1', orphans.first['identifier']
    assert_equal ['Some.Show.S01E01.1080p'], orphans.first['torrents'].map { |t| t['name'] }
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

  FakeResponse = TestSupport::Fakes::FakeResponse
end

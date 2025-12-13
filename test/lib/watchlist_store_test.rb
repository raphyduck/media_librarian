# frozen_string_literal: true

require 'ostruct'
require 'fileutils'
require 'tmpdir'
require_relative '../test_helper'
require_relative '../../lib/watchlist_store'
require_relative '../../lib/storage/db'
require_relative '../../lib/media_librarian/application'

class WatchlistStoreTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('watchlist-store-test')
    db_path = File.join(@root, 'db.sqlite3')
    db = Storage::Db.new(db_path)
    speaker = TestSupport::Fakes::Speaker.new
    @app = OpenStruct.new(db: db, speaker: speaker)
    MediaLibrarian.instance_variable_set(:@application, @app)
  end

  def teardown
    MediaLibrarian.instance_variable_set(:@application, nil)
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
  end

  def test_normalize_and_delete_use_imdb_id
    WatchlistStore.upsert([
      { imdb_id: 'tt1234567', type: 'movies', title: 'Example', metadata: { ids: { tmdb: '99' } } }
    ])

    rows = WatchlistStore.fetch
    assert_equal 1, rows.size
    row = rows.first
    assert_equal 'tt1234567', row[:imdb_id]
    refute_includes row.keys, :metadata

    assert_equal 1, WatchlistStore.delete(imdb_id: 'tt1234567')
    assert_empty WatchlistStore.fetch
  end

  def test_normalize_legacy_external_id_only
    WatchlistStore.upsert([
      { external_id: 'tt4242', type: 'movies', title: 'Legacy title' }
    ])

    row = WatchlistStore.fetch.first
    assert_equal 'tt4242', row[:imdb_id]
    refute_includes row.keys, :metadata
  end

  def test_fetch_with_details_enriches_rows
    @app.db.insert_row(
      'calendar_entries',
      source: 'tmdb', external_id: '42', title: 'Sample', media_type: 'movie', imdb_id: 'tt0042',
      release_date: '2024-03-01', ids: { imdb: 'tt0042' }
    )

    WatchlistStore.upsert([
      { imdb_id: 'tt0042', type: 'movies', title: 'Sample' }
    ])

    row = WatchlistStore.fetch_with_details.first
    assert_equal 'Sample', row[:title]
    assert_equal 'tt0042', row[:ids]['imdb']
    assert_equal 2024, row[:year]
  end
end

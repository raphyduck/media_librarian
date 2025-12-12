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
    assert_equal 'tt1234567', row[:external_id]
    assert_equal 'tt1234567', row[:metadata][:ids][:imdb]

    assert_equal 1, WatchlistStore.delete(imdb_id: 'tt1234567')
    assert_empty WatchlistStore.fetch
  end
end

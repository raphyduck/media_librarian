# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/calendar_entries_repository'

class CalendarEntriesRepositoryTest < Minitest::Test
  class FakeDb
    def initialize(calendar_rows:, local_rows:, tables: [:calendar_entries, :local_media])
      @calendar_rows = calendar_rows
      @local_rows = local_rows
      @tables = tables
    end

    def get_rows(table, *_args)
      case table.to_sym
      when :calendar_entries
        @calendar_rows
      when :local_media
        @local_rows
      else
        []
      end
    end

    def table_exists?(table)
      @tables.include?(table.to_sym)
    end
  end

  def setup
    @app = Struct.new(:db).new(nil)
  end

  def test_marks_entries_in_interest_list_when_watchlist_matches
    calendar_rows = [
      { media_type: 'movie', title: 'Alpha', imdb_id: 'tt1234' }
    ]

    WatchlistStore.stub(:fetch, [{ imdb_id: 'tt1234' }]) do
      @app.db = FakeDb.new(calendar_rows: calendar_rows, local_rows: [])

      entries = CalendarEntriesRepository.new(app: @app).load_entries

      assert entries.first[:in_interest_list]
    end
  end

  def test_marks_entries_downloaded_when_inventory_matches_imdb
    calendar_rows = [
      { media_type: 'movie', title: 'Alpha', ids: { 'imdb' => 'tt1234' } }
    ]
    local_rows = [
      { media_type: 'movies', imdb_id: 'tt1234', local_path: '/tmp/a' }
    ]
    @app.db = FakeDb.new(calendar_rows: calendar_rows, local_rows: local_rows)

    entries = CalendarEntriesRepository.new(app: @app).load_entries

    assert_equal 1, entries.length
    assert entries.first[:downloaded]
  end

  def test_skips_download_flag_when_local_media_table_missing
    calendar_rows = [
      { media_type: 'show', title: 'Bravo', ids: { 'tmdb' => '42' } }
    ]
    @app.db = FakeDb.new(calendar_rows: calendar_rows, local_rows: [], tables: [:calendar_entries])

    entries = CalendarEntriesRepository.new(app: @app).load_entries

    refute entries.first[:downloaded]
  end
end

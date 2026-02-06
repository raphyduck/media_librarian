# frozen_string_literal: true

ENV['SKIP_DB_MIGRATIONS'] = '1'

require 'json'
require 'ostruct'
require 'securerandom'
require_relative '../test_helper'
require_relative '../../app/collection_repository'
require_relative '../../lib/storage/db'
require_relative '../../app/daemon'

class CollectionRepositoryTest < Minitest::Test
  def setup
    @environment = build_stubbed_environment
    db_path = File.join(@environment.root_path, 'db.sqlite3')
    attach_db(Storage::Db.new(db_path, 0, migrations_path: nil))
    create_local_media_table
    create_calendar_entries_table
    CollectionRepository.configure(app: @environment.application)
    @repository = CollectionRepository.new(app: @environment.application)
  end

  def teardown
    @environment.cleanup
  end

  def test_paginated_entries_returns_sorted_results
    insert_media([
      { imdb_id: 'ttfuture', local_path: '/tmp/media/future.mkv', created_at: '2024-01-01T00:00:00Z' },
      { imdb_id: 'ttrecent', local_path: '/tmp/media/recent.mkv', created_at: '2023-06-01T00:00:00Z' },
      { imdb_id: 'ttclassic', local_path: '/tmp/media/classic.mkv', created_at: '1999-01-01T00:00:00Z' }
    ])

    result = @repository.paginated_entries(sort: 'released_at', page: 1, per_page: 2)

    assert_equal 3, result[:total]
    assert_equal %w[future.mkv recent.mkv], result[:entries].map { |entry| entry[:title] }
    assert result[:entries].first[:released_at].start_with?('2024-01-01')
  end

  def test_paginated_entries_clamps_page_and_per_page
    insert_media([{ imdb_id: 'ttsingle', local_path: '/tmp/media/single.mkv' }])

    result = @repository.paginated_entries(sort: 'title', page: -5, per_page: 1_000)

    assert_equal 1, result[:entries].size
    assert_equal 'single.mkv', result[:entries].first[:title]
  end

  def test_groups_entries_by_imdb_id
    insert_media([
      { imdb_id: 'ttgroup', local_path: '/tmp/media/first.mkv' },
      { imdb_id: 'ttgroup', local_path: '/tmp/media/second.mkv' }
    ])

    result = @repository.paginated_entries(sort: 'title', page: 1, per_page: 10)

    assert_equal 1, result[:total]
    assert_equal ['ttgroup'], result[:entries].map { |entry| entry[:imdb_id] }
    assert_equal ['/tmp/media/first.mkv', '/tmp/media/second.mkv'], result[:entries].first[:files]
  end

  def test_builds_seasons_for_tv_entries
    insert_media([
      { imdb_id: 'tttv', media_type: 'tv', local_path: '/tmp/media/Show.S01E01.mkv' },
      { imdb_id: 'tttv', media_type: 'tv', local_path: '/tmp/media/Show.1x02.mkv' }
    ])

    result = @repository.paginated_entries(sort: 'title', page: 1, per_page: 10)

    seasons = result[:entries].first[:seasons]
    assert_equal 1, seasons.size
    assert_equal 1, seasons.first[:season]
    assert_equal [1, 2], seasons.first[:episodes].map { |episode| episode[:episode] }
    assert_equal ['/tmp/media/Show.S01E01.mkv'], seasons.first[:episodes].first[:files]
    assert_equal ['/tmp/media/Show.1x02.mkv'], seasons.first[:episodes].last[:files]
  end

  def test_enriches_entries_with_calendar_metadata_when_available
    insert_media([{ imdb_id: 'ttmeta', local_path: '/tmp/media/meta.mkv', created_at: '2023-02-01T00:00:00Z' }])
    insert_calendar_entry(
      imdb_id: 'ttmeta',
      title: 'Metadata Title',
      release_date: '2020-05-04',
      poster_url: 'https://example.com/poster.jpg',
      backdrop_url: 'https://example.com/backdrop.jpg',
      synopsis: 'A story worth telling.',
      ids: { imdb: 'ttmeta', tmdb: 42 },
      source: 'tmdb',
      external_id: 'movie-42'
    )

    result = @repository.paginated_entries(sort: 'title', page: 1, per_page: 10)
    entry = result[:entries].first

    assert_equal 'Metadata Title', entry[:title]
    assert_equal 'Metadata Title', entry[:name]
    assert_equal 'https://example.com/poster.jpg', entry[:poster_url]
    assert_equal 'https://example.com/backdrop.jpg', entry[:backdrop_url]
    assert_equal 'A story worth telling.', entry[:synopsis]
    assert_equal({ 'imdb' => 'ttmeta', 'tmdb' => 42 }, entry[:ids])
    assert_equal 'tmdb', entry[:source]
    assert_equal 'movie-42', entry[:external_id]
    assert_equal 2020, entry[:year]
    assert entry[:released_at].start_with?('2020-05-04')
    assert_equal ['/tmp/media/meta.mkv'], entry[:files]
  end

  def test_search_matches_titles_from_media_and_calendar_entries
    insert_media([
      { imdb_id: 'ttlocal', title: 'Unique Title', local_path: '/tmp/media/local.mkv' },
      { imdb_id: 'ttcalendar', local_path: '/tmp/media/calendar.mkv' }
    ])
    insert_calendar_entry(imdb_id: 'ttcalendar', title: 'Calendar Highlight')

    local_result = @repository.paginated_entries(sort: 'title', page: 1, per_page: 10, search: 'unique')
    assert_equal ['Unique Title'], local_result[:entries].map { |entry| entry[:title] }

    calendar_result = @repository.paginated_entries(sort: 'title', page: 1, per_page: 10, search: ' highlight ')
    assert_equal ['Calendar Highlight'], calendar_result[:entries].map { |entry| entry[:title] }
  end

  private

  def insert_media(rows)
    rows.each do |row|
      @environment.application.db.insert_row(:local_media, base_row.merge(row), 1)
    end
  end

  def insert_calendar_entry(row)
    prepared = {
      id: SecureRandom.random_number(1000),
      source: 'tmdb',
      external_id: 'movie-1',
      title: 'Calendar Title',
      media_type: 'movie',
      release_date: '2020-01-01',
      created_at: '2020-01-01',
      updated_at: '2020-01-02'
    }.merge(row)

    prepared[:ids] = JSON.dump(prepared[:ids]) if prepared[:ids].is_a?(Hash)
    @environment.application.db.insert_row(:calendar_entries, prepared, 1)
  end

  def create_local_media_table
    @environment.application.db.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS local_media (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        media_type TEXT,
        imdb_id TEXT,
        title TEXT,
        local_path TEXT,
        created_at TEXT
      )
    SQL
  end

  def create_calendar_entries_table
    @environment.application.db.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS calendar_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source TEXT,
        external_id TEXT,
        title TEXT,
        media_type TEXT,
        release_date TEXT,
        poster_url TEXT,
        backdrop_url TEXT,
        synopsis TEXT,
        ids TEXT,
        imdb_id TEXT,
        created_at TEXT,
        updated_at TEXT
      )
    SQL
  end

  def base_row
    {
      media_type: 'movie',
      imdb_id: SecureRandom.uuid,
      local_path: '/tmp/media/file.mkv'
    }
  end
end

class CollectionRequestTest < Minitest::Test
  def setup
    @environment = build_stubbed_environment
    Daemon.configure(app: @environment.application)
  end

  def teardown
    @environment.cleanup
  end

  def test_handle_collection_request_clamps_numeric_params
    response = FakeResponse.new
    captured = nil
    fake_result = { entries: [], total: 42 }

    CollectionRepository.stub(:new, ->(app:) { FakeRepository.new(app: app, on_query: ->(**params) { captured = params; fake_result }) }) do
      request = OpenStruct.new(
        request_method: 'GET',
        query: { 'page' => '0', 'per_page' => '9999', 'sort' => 'invalid' },
        path: '/collection'
      )

      Daemon.send(:handle_collection_request, request, response)
    end

    assert_equal({ sort: 'released_at', page: 1, per_page: CollectionRepository::MAX_PER_PAGE, search: '', type: nil }, captured)
    parsed = JSON.parse(response.body)
    assert_equal({ 'page' => 1, 'per_page' => CollectionRepository::MAX_PER_PAGE, 'total' => 42 }, parsed['pagination'])
  end

  class FakeRepository
    def initialize(app:, on_query:)
      @app = app
      @on_query = on_query
    end

    def paginated_entries(**params)
      @on_query.call(**params)
    end
  end

  FakeResponse = TestSupport::Fakes::FakeResponse
end

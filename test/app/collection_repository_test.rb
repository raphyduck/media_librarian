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

  private

  def attach_db(db)
    singleton = @environment.application.singleton_class
    unless @environment.application.respond_to?(:db)
      singleton.class_eval do
        attr_accessor :db
      end
    end
    @environment.application.db = db
  end

  def insert_media(rows)
    rows.each do |row|
      @environment.application.db.insert_row(:local_media, base_row.merge(row), 1)
    end
  end

  def create_local_media_table
    @environment.application.db.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS local_media (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        media_type TEXT,
        imdb_id TEXT,
        local_path TEXT,
        created_at TEXT
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

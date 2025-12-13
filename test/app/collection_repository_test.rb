# frozen_string_literal: true

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
    attach_db(Storage::Db.new(db_path))
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

    assert_equal({ sort: 'released_at', page: 1, per_page: CollectionRepository::MAX_PER_PAGE, search: '' }, captured)
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

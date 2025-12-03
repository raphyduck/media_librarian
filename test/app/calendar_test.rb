# frozen_string_literal: true

require 'test_helper'
require 'ostruct'
require_relative '../../lib/watchlist_store'
require_relative '../../app/calendar'
require_relative '../../app/daemon'

class CalendarTest < Minitest::Test
  def setup
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Calendar.clear_cache
  end

  def teardown
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def test_filters_by_genre_type_and_interest_flag
    db = stub_calendar_rows([
      {
        source: 'tmdb',
        external_id: 'movie-1',
        title: 'Alpha',
        media_type: 'movie',
        genres: ['Drama'],
        languages: ['en'],
        countries: ['US'],
        rating: 7.2,
        release_date: '2020-01-01'
      },
      {
        source: 'tmdb',
        external_id: 'show-1',
        title: 'Bravo',
        media_type: 'show',
        genres: ['Comedy'],
        languages: ['fr'],
        countries: ['FR'],
        rating: 8.0,
        release_date: '2021-06-01'
      }
    ])

    WatchlistStore.stub(:fetch, [{ external_id: 'movie-1', type: 'movies', metadata: {} }]) do
      calendar = Calendar.new(app: @environment.application)
      result = calendar.entries(type: 'movie', genres: ['Drama'], interest: 'true')

      assert_equal 1, result[:total]
      entry = result[:entries].first
      assert_equal 'Alpha', entry[:title]
      assert entry[:in_interest_list]
      assert_equal %w[en], entry[:languages]
      assert_equal 'movie', entry[:type]
    end

    db.verify
  end

  def test_paginates_and_sorts_by_release_date
    db = stub_calendar_rows([
      {
        source: 'tmdb',
        external_id: 'movie-1',
        title: 'First',
        media_type: 'movie',
        release_date: '2018-01-01'
      },
      {
        source: 'tmdb',
        external_id: 'movie-2',
        title: 'Second',
        media_type: 'movie',
        release_date: '2019-01-01'
      }
    ])

    WatchlistStore.stub(:fetch, []) do
      calendar = Calendar.new(app: @environment.application)
      page_two = calendar.entries(sort: 'desc', per_page: 1, page: 2)

      assert_equal 2, page_two[:total]
      assert_equal 2, page_two[:total_pages]
      assert_equal ['First'], page_two[:entries].map { |entry| entry[:title] }
    end

    db.verify
  end

  def test_filters_by_release_date_range
    db = stub_calendar_rows([
      { source: 'tmdb', external_id: 'movie-1', title: 'Alpha', media_type: 'movie', release_date: '2024-01-05' },
      { source: 'tmdb', external_id: 'movie-2', title: 'Bravo', media_type: 'movie', release_date: '2024-01-20' },
      { source: 'tmdb', external_id: 'movie-3', title: 'Charlie', media_type: 'movie', release_date: '2024-02-01' }
    ])

    WatchlistStore.stub(:fetch, []) do
      calendar = Calendar.new(app: @environment.application)
      result = calendar.entries(start_date: '2024-01-10', end_date: '2024-01-31')

      assert_equal ['Bravo'], result[:entries].map { |entry| entry[:title] }
    end

    db.verify
  end

  def test_filters_by_imdb_vote_range
    db = stub_calendar_rows([
      { source: 'imdb', external_id: 'movie-1', title: 'Alpha', media_type: 'movie', imdb_votes: 500 },
      { source: 'imdb', external_id: 'movie-2', title: 'Bravo', media_type: 'movie', imdb_votes: 1200 },
      { source: 'imdb', external_id: 'movie-3', title: 'Charlie', media_type: 'movie', imdb_votes: nil }
    ])

    WatchlistStore.stub(:fetch, []) do
      calendar = Calendar.new(app: @environment.application)
      result = calendar.entries(imdb_votes_min: '800', imdb_votes_max: '1500')

      assert_equal ['Bravo'], result[:entries].map { |entry| entry[:title] }
    end

    db.verify
  end

  def test_handle_calendar_request_uses_offset_and_window
    Daemon.configure(app: @environment.application)
    response = FakeResponse.new
    filters = nil

    Time.stub(:now, Time.utc(2024, 1, 1, 12, 0, 0)) do
      Calendar.stub(:new, ->(app:) { FakeCalendar.new(app: app, on_entries: ->(args) { filters = args }) }) do
        request = OpenStruct.new(request_method: 'GET', query: { 'offset' => '1', 'window' => '7' }, path: '/calendar')
        Daemon.send(:handle_calendar_request, request, response)
      end
    end

    assert_equal 200, response.status
    assert_kind_of Time, filters[:start_date]
    assert_kind_of Time, filters[:end_date]
    assert_equal Time.utc(2024, 1, 8), filters[:start_date]
    assert_equal Time.utc(2024, 1, 14), filters[:end_date]
  end

  private

  def stub_calendar_rows(rows)
    db = Minitest::Mock.new
    db.expect(:get_rows, rows, [:calendar_entries])
    attach_db(db)
    db
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

  class FakeCalendar
    def initialize(app:, on_entries: nil)
      @app = app
      @on_entries = on_entries
    end

    def entries(filters)
      @on_entries.call(filters) if @on_entries
      { entries: [], page: 1, per_page: 50, total: 0, total_pages: 0 }
    end
  end

  def attach_db(db)
    singleton = @environment.application.singleton_class
    unless @environment.application.respond_to?(:db)
      singleton.class_eval do
        attr_accessor :db
      end
    end
    @environment.application.db = db
  end
end

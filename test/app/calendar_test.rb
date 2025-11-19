# frozen_string_literal: true

require 'test_helper'
require_relative '../../lib/watchlist_store'
require_relative '../../app/calendar'

class CalendarTest < Minitest::Test
  def setup
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Calendar.cache[:data] = []
    Calendar.cache[:expires_at] = nil
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

  private

  def stub_calendar_rows(rows)
    db = Minitest::Mock.new
    db.expect(:get_rows, rows, [:calendar_entries])
    attach_db(db)
    db
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

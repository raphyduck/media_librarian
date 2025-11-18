# frozen_string_literal: true

require 'test_helper'
require 'ostruct'
require_relative '../../lib/trakt_agent'
require_relative '../../app/movie'
require_relative '../../app/tv_series'
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

  def test_filters_by_genre_type_and_download_flag
    trakt_stub = lambda do |name, type|
      case [name, type]
      when ['watchlist', 'movies']
        [{ 'movie' => { 'ids' => { 'imdb' => 'tt-movie' } } }]
      when ['watchlist', 'shows']
        [{ 'show' => { 'ids' => { 'imdb' => 'tt-show' } } }]
      when ['collection', 'movies']
        [{ 'movie' => { 'ids' => { 'imdb' => 'tt-movie' } } }]
      else
        []
      end
    end

    movie = OpenStruct.new(
      name: 'Alpha',
      year: 2020,
      genres: ['Drama'],
      language: 'en',
      country: 'US',
      rating: 7.2,
      release_date: Time.utc(2020, 1, 1)
    )

    show = OpenStruct.new(
      name: 'Bravo',
      year: 2021,
      genres: ['Comedy'],
      language: 'fr',
      country: 'FR',
      rating: 8.0,
      first_aired: Time.utc(2021, 6, 1)
    )

    TraktAgent.stub(:list, trakt_stub) do
      Movie.stub(:movie_get, ->(*_) { ['', movie] }) do
        TvSeries.stub(:tv_show_get, ->(*_) { ['', show] }) do
          calendar = Calendar.new(app: @environment.application)
          result = calendar.entries(type: 'movie', genres: ['Drama'], downloaded: 'true')

          assert_equal 1, result[:total]
          entry = result[:entries].first
          assert_equal 'Alpha', entry[:title]
          assert entry[:downloaded]
          assert entry[:in_interest_list]
          assert_equal 'movie', entry[:type]
        end
      end
    end
  end

  def test_paginates_and_sorts_by_release_date
    trakt_stub = lambda do |name, type|
      return [] unless name == 'watchlist' && type == 'movies'

      [
        { 'movie' => { 'ids' => { 'imdb' => 'tt-1' } } },
        { 'movie' => { 'ids' => { 'imdb' => 'tt-2' } } }
      ]
    end

    first = OpenStruct.new(
      name: 'First',
      year: 2018,
      genres: [],
      language: 'en',
      country: 'US',
      rating: 7.0,
      release_date: Time.utc(2018, 1, 1)
    )

    second = OpenStruct.new(
      name: 'Second',
      year: 2019,
      genres: [],
      language: 'en',
      country: 'US',
      rating: 7.5,
      release_date: Time.utc(2019, 1, 1)
    )

    TraktAgent.stub(:list, trakt_stub) do
      call_count = 0
      Movie.stub(:movie_get, lambda do |ids, *|
        call_count += 1
        ids['imdb'] == 'tt-1' ? ['', first] : ['', second]
      end) do
        calendar = Calendar.new(app: @environment.application)
        page_two = calendar.entries(sort: 'desc', per_page: 1, page: 2)

        assert_equal 2, page_two[:total]
        assert_equal 2, page_two[:total_pages]
        assert_equal ['First'], page_two[:entries].map { |entry| entry[:title] }
        assert_equal 2, call_count
      end
    end
  end
end

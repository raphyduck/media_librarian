# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'date'

require_relative 'service_test_helper'
require_relative '../../app/media_librarian/services/base_service'
require_relative '../../app/media_librarian/services/calendar_feed_service'
require_relative '../../lib/storage/db'
require_relative '../../lib/trakt_agent'

class CalendarFeedServiceTest < Minitest::Test
  class FakeProvider
    attr_reader :calls

    def initialize(entries, source: 'fake')
      @entries = entries
      @calls = []
      @source = source
    end

    def upcoming(date_range:, limit:)
      @calls << { range: date_range, limit: limit }
      @entries
    end

    def source
      @source
    end
  end

  def setup
    @tmp_dir = Dir.mktmpdir('calendar-feed')
    @db_path = File.join(@tmp_dir, 'librarian.db')
    @db = Storage::Db.new(@db_path, migrations_path: nil)
    ensure_calendar_table
    @speaker = TestSupport::Fakes::Speaker.new
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir && Dir.exist?(@tmp_dir)
  end

  def test_refresh_persists_entries
    provider = FakeProvider.new([
      base_entry.merge(external_id: 'movie-1', title: 'Test Movie', genres: ['Drama']),
      base_entry.merge(
        external_id: 'show-2',
        title: 'Test Show',
        media_type: 'show',
        genres: ['Sci-Fi'],
        languages: ['en', 'fr'],
        release_date: Date.today + 2
      )
    ])

    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db, providers: [provider])

    service.refresh(date_range: Date.today..(Date.today + 5), limit: 10)

    rows = @db.get_rows(:calendar_entries).sort_by { |row| row[:external_id] }
    assert_equal 2, rows.count
    assert_equal ['Drama'], rows.first[:genres]
    assert_equal 'movie', rows.first[:media_type]
    assert_equal 'Test Show', rows.last[:title]
    assert_equal %w[en fr], rows.last[:languages]
    assert_equal 'https://example.test/poster.jpg', rows.first[:poster_url]
  end

  def test_refresh_replaces_duplicates
    initial_provider = FakeProvider.new([
      base_entry.merge(external_id: 'movie-1', title: 'First Title', rating: 6.4)
    ])
    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db, providers: [initial_provider])
    service.refresh(date_range: Date.today..(Date.today + 3), limit: 5)

    updated_provider = FakeProvider.new([
      base_entry.merge(external_id: 'movie-1', title: 'First Title', rating: 8.2, languages: ['fr'])
    ])
    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db, providers: [updated_provider])
    service.refresh(date_range: Date.today..(Date.today + 3), limit: 5)

    rows = @db.get_rows(:calendar_entries, { source: 'fake', external_id: 'movie-1' })
    assert_equal 1, rows.count
    assert_in_delta 8.2, rows.first[:rating]
    assert_equal ['fr'], rows.first[:languages]
  end

  def test_refresh_filters_to_requested_sources
    first_provider = FakeProvider.new([
      base_entry.merge(source: 'first', external_id: 'movie-1', title: 'First Title')
    ], source: 'first')
    second_provider = FakeProvider.new([
      base_entry.merge(source: 'second', external_id: 'movie-2', title: 'Second Title')
    ], source: 'second')

    service = MediaLibrarian::Services::CalendarFeedService.new(
      app: nil,
      speaker: @speaker,
      db: @db,
      providers: [first_provider, second_provider]
    )

    service.refresh(date_range: Date.today..(Date.today + 3), limit: 5, sources: ['second'])

    assert_empty first_provider.calls
    refute_empty second_provider.calls
    rows = @db.get_rows(:calendar_entries)
    assert_equal %w[second], rows.map { |row| row[:source] }.uniq
  end

  def test_refresh_handles_provider_failures
    failing_provider = Class.new do
      def source = 'failing'

      def upcoming(**)
        raise 'boom'
      end
    end.new
    working_provider = FakeProvider.new([
      base_entry.merge(source: 'working', external_id: 'movie-1', title: 'Working Title')
    ], source: 'working')

    service = MediaLibrarian::Services::CalendarFeedService.new(
      app: nil,
      speaker: @speaker,
      db: @db,
      providers: [failing_provider, working_provider]
    )

    service.refresh(date_range: Date.today..(Date.today + 1), limit: 5)

    assert @speaker.messages.any? { |msg| msg.first == :error && msg.last.to_s.include?('Calendar provider failure') }
    rows = @db.get_rows(:calendar_entries)
    assert_equal 1, rows.count
    assert_equal 'working', rows.first[:source]
  end

  def test_default_providers_come_from_config
    config = {
      'tmdb' => { 'api_key' => '123', 'language' => 'en', 'region' => 'US' },
      'imdb' => {},
      'trakt' => { 'client_id' => 'id', 'client_secret' => 'secret' }
    }
    app = Struct.new(:config, :db).new(config, @db)

    service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

    sources = service.send(:default_providers).map(&:source)
    assert_includes sources, 'tmdb'
    assert_includes sources, 'imdb'
    assert_includes sources, 'trakt'
  end

  def test_imdb_provider_enabled_with_empty_configuration
    config = { 'imdb' => {} }
    app = Struct.new(:config, :db).new(config, @db)

    service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

    sources = service.send(:default_providers).map(&:source)
    assert_includes sources, 'imdb'
  end

  def test_imdb_provider_enabled_when_configuration_absent
    config = {}
    app = Struct.new(:config, :db).new(config, @db)

    service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

    sources = service.send(:default_providers).map(&:source)
    assert_includes sources, 'imdb'
  end

  def test_imdb_provider_can_be_disabled
    config = { 'imdb' => { 'enabled' => false } }
    app = Struct.new(:config, :db).new(config, @db)

    service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

    sources = service.send(:default_providers).map(&:source)
    refute_includes sources, 'imdb'
  end

  def test_normalization_downcases_sources
    date = Date.today + 1
    tmdb_provider = FakeProvider.new([
      base_entry.merge(source: 'TMDB', external_id: 'tmdb-1', title: 'TMDB Title')
    ], source: 'TMDB')
    imdb_provider = MediaLibrarian::Services::CalendarFeedService::ImdbCalendarProvider.new(
      speaker: @speaker,
      fetcher: ->(**_) { [{ external_id: 'imdb-1', title: 'IMDb Title', media_type: 'movie', release_date: date }] }
    )
    trakt_provider = MediaLibrarian::Services::CalendarFeedService::TraktCalendarProvider.new(
      client_id: 'id', client_secret: 'secret', speaker: @speaker,
      fetcher: ->(**_) { [{ external_id: 'trakt-1', title: 'Trakt Title', media_type: 'show', release_date: date }] }
    )

    service = MediaLibrarian::Services::CalendarFeedService.new(
      app: nil,
      speaker: @speaker,
      db: @db,
      providers: [tmdb_provider, imdb_provider, trakt_provider]
    )

    service.refresh(date_range: Date.today..(Date.today + 3), limit: 10)

    rows = @db.get_rows(:calendar_entries).sort_by { |row| row[:external_id] }
    assert_equal %w[imdb tmdb trakt], rows.map { |row| row[:source] }.uniq.sort
    assert_equal %w[movie movie show], rows.map { |row| row[:media_type] }
  end

  def test_imdb_provider_fetches_via_imdb_party_client
    movie_date = Date.today + 1
    show_date = Date.today + 2
    date_range = Date.today..(Date.today + 5)
    calendar_items = [
      {
        'id' => 'tt0111161',
        'titleText' => { 'text' => 'The Shawshank Redemption' },
        'titleType' => { 'text' => 'Feature Film' },
        'releaseDate' => movie_date,
        'genres' => { 'genres' => [{ 'text' => 'Drama' }] },
        'spokenLanguages' => [{ 'text' => 'English' }],
        'countriesOfOrigin' => [{ 'text' => 'United States' }],
        'ratingsSummary' => { 'aggregateRating' => 9.3 }
      },
      {
        'id' => 'tt7654321',
        'titleText' => { 'text' => 'New Series' },
        'titleType' => { 'text' => 'TV Series' },
        'releaseDate' => show_date,
        'genres' => { 'genres' => [{ 'text' => 'Sci-Fi' }] },
        'spokenLanguages' => [{ 'text' => 'French' }],
        'countriesOfOrigin' => [{ 'text' => 'Canada' }],
        'ratingsSummary' => { 'aggregateRating' => 7.5 }
      }
    ]

    client = Object.new
    client.define_singleton_method(:calendar_calls) { @calendar_calls ||= [] }
    client.define_singleton_method(:respond_to?) do |method_name, include_all = false|
      method_name == :calendar || super(method_name, include_all)
    end
    client.define_singleton_method(:calendar) do |date_range:, limit:|
      calendar_calls << { date_range: date_range, limit: limit }
      calendar_items
    end

    ImdbParty::Imdb.stub :new, client do
      config = { 'imdb' => {} }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)
      assert_includes service.send(:providers).map(&:source), 'imdb'

      service.refresh(date_range: date_range, limit: 5, sources: ['imdb'])
    end

    assert_equal [{ date_range: date_range, limit: 5 }], client.calendar_calls
    rows = @db.get_rows(:calendar_entries, { source: 'imdb' }).sort_by { |row| row[:external_id] }
    assert_equal 2, rows.count
    assert_equal 'movie', rows.first[:media_type]
    assert_equal ['Drama'], rows.first[:genres]
    assert_equal ['English'], rows.first[:languages]
    assert_equal ['United States'], rows.first[:countries]
    assert_equal 'show', rows.last[:media_type]
    assert_equal ['Sci-Fi'], rows.last[:genres]
    assert_equal ['French'], rows.last[:languages]
    assert_equal ['Canada'], rows.last[:countries]
  end

  def test_imdb_provider_falls_back_to_tmdb_when_feed_empty
    date = Date.today + 2
    imdb_provider = MediaLibrarian::Services::CalendarFeedService::ImdbCalendarProvider.new(
      speaker: @speaker,
      fetcher: ->(**_) { [] }
    )
    tmdb_entries = [
      base_entry.merge(source: 'tmdb', external_id: 'tmdb-1', title: 'Fallback Movie', release_date: date)
    ]
    tmdb_provider = FakeProvider.new(tmdb_entries, source: 'tmdb')

    service = MediaLibrarian::Services::CalendarFeedService.new(
      app: nil,
      speaker: @speaker,
      db: @db,
      providers: [imdb_provider, tmdb_provider]
    )

    service.refresh(date_range: Date.today..(Date.today + 5), limit: 5, sources: ['imdb'])

    rows = @db.get_rows(:calendar_entries)
    assert_equal 1, rows.count
    assert_equal 'tmdb', rows.first[:source]
    assert_equal 1, tmdb_provider.calls.count
  end

  def test_trakt_provider_fetches_remote_calendar
    start_date = Date.today
    end_date = start_date + 5
    date_range = start_date..end_date
    days = (end_date - start_date).to_i + 1
    movie_payload = [
      {
        'released' => (start_date + 1).to_s,
        'movie' => {
          'title' => 'Trakt Movie',
          'ids' => { 'slug' => 'trakt-movie' },
          'genres' => ['drama'],
          'language' => 'en',
          'country' => 'us',
          'rating' => 7.3
        }
      }
    ]
    show_payload = [
      {
        'first_aired' => (start_date + 2).to_s,
        'show' => {
          'title' => 'Trakt Show',
          'ids' => { 'slug' => 'trakt-show' },
          'genres' => ['sci-fi'],
          'language' => 'en',
          'country' => 'gb',
          'rating' => 8.1
        }
      }
    ]

    movie_calls = []
    show_calls = []

    TraktAgent.stub(
      :calendars__all_movies,
      ->(start_date, days) { movie_calls << [start_date, days]; movie_payload }
    ) do
      TraktAgent.stub(
        :calendars__all_shows,
        ->(start_date, days) { show_calls << [start_date, days]; show_payload }
      ) do
        config = { 'trakt' => { 'client_id' => 'id', 'client_secret' => 'secret' } }
        app = Struct.new(:config, :db).new(config, @db)
        service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

        service.refresh(date_range: date_range, limit: 10, sources: ['trakt'])
      end
    end

    assert_equal [[start_date, days]], movie_calls
    assert_equal [[start_date, days]], show_calls
    rows = @db.get_rows(:calendar_entries, { source: 'trakt' })
    assert_equal 2, rows.count
    movie = rows.find { |row| row[:media_type] == 'movie' }
    show = rows.find { |row| row[:media_type] == 'show' }
    assert_equal ['drama'], movie[:genres]
    assert_equal ['en'], movie[:languages]
    assert_equal ['gb'], show[:countries]
    assert_equal ['sci-fi'], show[:genres]
  end

  def test_tmdb_fetch_page_handles_movies_and_shows_without_argument_errors
    client = fake_tmdb_client
    provider = MediaLibrarian::Services::CalendarFeedService::TmdbCalendarProvider.new(
      api_key: '123', language: 'en', region: 'US', speaker: @speaker, client: client
    )

    movie_page = provider.send(:fetch_page, '/movie/upcoming', :movie, 1)
    tv_page = provider.send(:fetch_page, '/tv/on_the_air', :tv, 2)

    assert_equal 3, movie_page['total_pages']
    assert_equal 3, tv_page['total_pages']
    assert_equal [['/tv/on_the_air', { page: 2 }]], client::Api.requests
  end

  private

  def base_entry
    {
      source: 'fake',
      external_id: 'base-id',
      title: 'Base',
      media_type: 'movie',
      genres: [],
      languages: ['en'],
      countries: ['US'],
      rating: 7.1,
      poster_url: 'https://example.test/poster.jpg',
      backdrop_url: 'https://example.test/backdrop.jpg',
      release_date: Date.today + 1
    }
  end

  def ensure_calendar_table
    return if @db.database.table_exists?(:calendar_entries)

    @db.database.create_table :calendar_entries do
      primary_key :id
      String :source, size: 50, null: false
      String :external_id, size: 200, null: false
      String :title, size: 500, null: false
      String :media_type, size: 50, null: false
      Text :genres
      Text :languages
      Text :countries
      String :poster_url, size: 500
      String :backdrop_url, size: 500
      Float :rating
      Date :release_date
      DateTime :created_at
      DateTime :updated_at

      index %i[source external_id], unique: true
      index :release_date
    end
  end

  def fake_tmdb_client
    Module.new do
      api_mod = Module.new do
        class << self
          attr_accessor :requests

          def key(*)
            nil
          end

          def language(*)
            nil
          end

          def config
            @config ||= {}
          end

          def request(path, params = {})
            self.requests ||= []
            self.requests << [path, params]
            { 'results' => [], 'total_pages' => 3 }
          end
        end
      end

      movie_mod = Module.new do
        def self.upcoming
          { 'results' => [], 'total_pages' => 3 }
        end

        def self.detail(*)
          {}
        end
      end

      tv_mod = Module.new do
        def self.on_the_air
          { 'results' => [], 'total_pages' => 3 }
        end

        def self.detail(*)
          {}
        end
      end

      const_set(:Api, api_mod)
      const_set(:Movie, movie_mod)
      const_set(:TV, tv_mod)
    end
  end

end

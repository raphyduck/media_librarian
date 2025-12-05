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
    assert_equal 321, rows.first[:imdb_votes]
  end

  def test_refresh_logs_collection_and_persistence_counts
    provider = FakeProvider.new([
      base_entry.merge(external_id: 'movie-1', title: 'Logged Movie')
    ])

    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db, providers: [provider])

    service.refresh(date_range: Date.today..(Date.today + 1), limit: 5)

    assert_includes @speaker.messages, 'Calendar feed collected 1 items'
    assert @speaker.messages.any? { |msg| msg.start_with?('Calendar feed persisted 1 items') }
  end

  def test_refresh_replaces_duplicates
    initial_provider = FakeProvider.new([
      base_entry.merge(external_id: 'movie-1', title: 'First Title', rating: 6.4, imdb_votes: 10)
    ])
    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db, providers: [initial_provider])
    service.refresh(date_range: Date.today..(Date.today + 3), limit: 5)

    updated_provider = FakeProvider.new([
      base_entry.merge(external_id: 'movie-1', title: 'First Title', rating: 8.2, languages: ['fr'], imdb_votes: 12)
    ])
    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db, providers: [updated_provider])
    service.refresh(date_range: Date.today..(Date.today + 3), limit: 5)

    rows = @db.get_rows(:calendar_entries, { source: 'fake', external_id: 'movie-1' })
    assert_equal 1, rows.count
    assert_in_delta 8.2, rows.first[:rating]
    assert_equal ['fr'], rows.first[:languages]
    assert_equal 12, rows.first[:imdb_votes]
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

    assert @speaker.messages.any? { |msg| msg.is_a?(Array) && msg.first == :error && msg.last.to_s.include?('Calendar provider failure') }
    rows = @db.get_rows(:calendar_entries)
    assert_equal 1, rows.count
    assert_equal 'working', rows.first[:source]
  end

  def test_default_providers_come_from_config
    config = {
      'tmdb' => { 'api_key' => '123', 'language' => 'en', 'region' => 'US' },
      'imdb' => {},
      'trakt' => { 'account_id' => 'acc', 'client_id' => 'id', 'client_secret' => 'secret' }
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
      account_id: 'acc', client_id: 'id', client_secret: 'secret', speaker: @speaker,
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

  def test_imdb_provider_fetches_via_imdb_api_helper
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
        'ratingsSummary' => { 'aggregateRating' => 9.3, 'voteCount' => 123_456 }
      },
      {
        'id' => 'tt7654321',
        'titleText' => { 'text' => 'New Series' },
        'titleType' => { 'text' => 'TV Series' },
        'releaseDate' => show_date,
        'genres' => { 'genres' => [{ 'text' => 'Sci-Fi' }] },
        'spokenLanguages' => [{ 'text' => 'French' }],
        'countriesOfOrigin' => [{ 'text' => 'Canada' }],
        'ratingsSummary' => { 'aggregateRating' => 7.5, 'voteCount' => 6_789 }
      }
    ]

    helper = Class.new do
      attr_reader :calls

      def initialize(calendar_items)
        @calendar_items = calendar_items
        @calls = []
      end

      def calendar(date_range:, limit:)
        @calls << { date_range: date_range, limit: limit }
        @calendar_items
      end
    end.new(calendar_items)

    ImdbApi.stub :new, ->(**_) { helper } do
      config = { 'imdb' => { 'base_url' => 'https://example.test' } }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)
      assert_includes service.send(:providers).map(&:source), 'imdb'

      service.refresh(date_range: date_range, limit: 5, sources: ['imdb'])
    end

    assert_equal [{ date_range: date_range, limit: 5 }], helper.calls
    rows = @db.get_rows(:calendar_entries, { source: 'imdb' }).sort_by { |row| row[:external_id] }
    assert_equal 2, rows.count
    assert_equal 'movie', rows.first[:media_type]
    assert_equal ['Drama'], rows.first[:genres]
    assert_equal ['English'], rows.first[:languages]
    assert_equal ['United States'], rows.first[:countries]
    assert_equal 123_456, rows.first[:imdb_votes]
    assert_equal 'show', rows.last[:media_type]
    assert_equal ['Sci-Fi'], rows.last[:genres]
    assert_equal ['French'], rows.last[:languages]
    assert_equal ['Canada'], rows.last[:countries]
    assert_equal 6_789, rows.last[:imdb_votes]
  end

  def test_imdb_calendar_fetches_past_and_upcoming_titles
    past_date = Date.today - 1
    future_date = Date.today + 2
    date_range = past_date..future_date

    helper = Class.new do
      attr_reader :calls

      def initialize(past_date, future_date)
        @past_date = past_date
        @future_date = future_date
        @calls = []
      end

      def calendar(date_range:, limit:)
        @calls << { date_range: date_range, limit: limit }
        [
          { 'id' => 'tt0100001', 'titleText' => { 'text' => 'Past Title' }, 'releaseDate' => @past_date },
          { 'id' => 'tt0200002', 'titleText' => { 'text' => 'Future Title' }, 'releaseDate' => @future_date }
        ]
      end
    end.new(past_date, future_date)

    ImdbApi.stub :new, ->(**_) { helper } do
      config = { 'imdb' => {} }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

      service.refresh(date_range: date_range, limit: 10, sources: ['imdb'])
    end

    assert_equal [{ date_range: date_range, limit: 10 }], helper.calls
    rows = @db.get_rows(:calendar_entries, { source: 'imdb' }).sort_by { |row| row[:title] }
    assert_equal ['Future Title', 'Past Title'], rows.map { |row| row[:title] }
  end

  def test_imdb_fetcher_logs_missing_calendar_support
    date_range = Date.today..(Date.today + 1)
    helper = Class.new do
      def calendar(**_args)
        []
      end
    end

    ImdbApi.stub :new, ->(**_) { helper.new } do
      config = { 'imdb' => {} }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

      service.refresh(date_range: date_range, limit: 5, sources: ['imdb'])
    end

    assert_includes @speaker.messages, "IMDb calendar fetch #{date_range.first}..#{date_range.last} (limit: 5)"
  end

  def test_imdb_fetcher_logs_calls_and_errors
    date_range = Date.today..(Date.today + 3)
    helper = Class.new do
      def calendar(**_args)
        raise StandardError, 'calendar exploded'
      end
    end.new

    ImdbApi.stub :new, ->(**_) { helper } do
      config = { 'imdb' => {} }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

      service.refresh(date_range: date_range, limit: 2, sources: ['imdb'])
    end

    assert_includes @speaker.messages, "IMDb calendar fetch #{date_range.first}..#{date_range.last} (limit: 2)"
    assert @speaker.messages.any? { |msg| msg.is_a?(Array) && msg.first == :error && msg[1].is_a?(StandardError) && msg.last == 'IMDB calendar fetch failed' }
  end

  def test_imdb_fetcher_reports_http_errors
    date_range = Date.today..Date.today
    response = Struct.new(:code, :body).new(500, 'failed')
    client = Class.new do
      def initialize(response)
        @response = response
      end

      def get(*_args)
        @response
      end
    end.new(response)

    api = ImdbApi.new(http_client: client, speaker: @speaker)

    ImdbApi.stub :new, ->(**_) { api } do
      config = { 'imdb' => {} }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

      service.refresh(date_range: date_range, limit: 1, sources: ['imdb'])
    end

    errors = @speaker.messages.select { |msg| msg.is_a?(Array) && msg.first == :error }
    assert errors.any? { |msg| msg[1].message.include?('status 500') }
    assert errors.any? { |msg| msg.last == 'IMDB calendar fetch failed' }
  end

  def test_imdb_fetcher_reports_empty_responses
    date_range = Date.today..Date.today
    response = Struct.new(:code, :body).new(200, '')
    client = Class.new do
      def initialize(response)
        @response = response
      end

      def get(*_args)
        @response
      end
    end.new(response)

    api = ImdbApi.new(http_client: client, speaker: @speaker)

    ImdbApi.stub :new, ->(**_) { api } do
      config = { 'imdb' => {} }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

      service.refresh(date_range: date_range, limit: 1, sources: ['imdb'])
    end

    errors = @speaker.messages.select { |msg| msg.is_a?(Array) && msg.first == :error }
    assert errors.any? { |msg| msg[1].message.include?('response was empty') }
    assert errors.any? { |msg| msg.last == 'IMDB calendar fetch failed' }
  end

  def test_imdb_provider_logs_empty_results
    date_range = Date.today..(Date.today + 1)
    imdb_provider = MediaLibrarian::Services::CalendarFeedService::ImdbCalendarProvider.new(
      speaker: @speaker,
      fetcher: ->(**_) { [] }
    )

    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db, providers: [imdb_provider])

    service.refresh(date_range: date_range, limit: 3, sources: ['imdb'])

    expected_message = "Calendar provider imdb returned no entries for #{date_range.first}..#{date_range.last}"
    assert_includes @speaker.messages, expected_message
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
          'ids' => { 'slug' => 'trakt-movie', 'imdb' => 'tt7777777', 'tmdb' => 555, 'trakt' => 1111 },
          'genres' => ['drama'],
          'language' => 'en',
          'country' => 'us',
          'rating' => 7.3,
          'votes' => 50
        }
      }
    ]
    show_payload = [
      {
        'first_aired' => (start_date + 2).to_s,
        'show' => {
          'title' => 'Trakt Show',
          'ids' => { 'slug' => 'trakt-show', 'tmdb' => 333, 'trakt' => 2222 },
          'genres' => ['sci-fi'],
          'language' => 'en',
          'country' => 'gb',
          'rating' => 8.1,
          'votes' => 75
        }
      }
    ]

    fetcher_instance = nil
    calendars = Class.new do
      attr_reader :calls

      def initialize(movie_payload, show_payload)
        @movie_payload = movie_payload
        @show_payload = show_payload
        @calls = []
      end

      def all_movies(start_date, days)
        @calls << [:movies, start_date, days]
        @movie_payload
      end

      def all_shows(start_date, days)
        @calls << [:shows, start_date, days]
        @show_payload
      end
    end.new(movie_payload, show_payload)

    fake_fetcher_class = Class.new do
      attr_reader :token, :account_id

      def initialize(token, calendars, account_id)
        @token = token
        @calendars = calendars
        @account_id = account_id
      end

      def calendars
        @calendars
      end
    end

    Trakt.stub(:new, ->(opts) { fetcher_instance = fake_fetcher_class.new(opts[:token], calendars, opts[:account_id]) }) do
      config = { 'trakt' => { 'account_id' => 'acc', 'client_id' => 'id', 'client_secret' => 'secret', 'access_token' => 'tok' } }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

      service.refresh(date_range: date_range, limit: 10, sources: ['trakt'])
    end

    assert_equal [[:movies, start_date, days], [:shows, start_date, days]], calendars.calls
    assert_equal({ access_token: 'tok' }, fetcher_instance.token)
    assert_equal 'acc', fetcher_instance.account_id
    rows = @db.get_rows(:calendar_entries, { source: 'trakt' })
    assert_equal 2, rows.count
    movie = rows.find { |row| row[:media_type] == 'movie' }
    show = rows.find { |row| row[:media_type] == 'show' }
    assert_equal ['drama'], movie[:genres]
    assert_equal ['en'], movie[:languages]
    assert_equal ['gb'], show[:countries]
    assert_equal ['sci-fi'], show[:genres]
    assert_equal 'tt7777777', movie[:ids][:imdb]
    assert_equal 555, movie[:ids][:tmdb]
    assert_equal 'trakt-show', show[:ids][:slug]
    assert_equal 2222, show[:ids][:trakt]
    assert_nil movie[:imdb_votes]
    assert_nil show[:imdb_votes]
  end

  def test_trakt_fetcher_uses_app_token_when_config_token_missing
    date_range = Date.today..(Date.today + 1)
    start_date = date_range.first
    days = (date_range.last - start_date).to_i + 1

    calendars = Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def all_movies(start_date, days)
        @calls << [:movies, start_date, days]
        []
      end

      def all_shows(start_date, days)
        @calls << [:shows, start_date, days]
        []
      end
    end.new

    fetcher_instance = nil
    fake_fetcher_class = Class.new do
      attr_reader :token

      def initialize(token, calendars)
        @token = token
        @calendars = calendars
      end

      def calendars
        @calendars
      end
    end

    Trakt.stub(:new, ->(opts) { fetcher_instance = fake_fetcher_class.new(opts[:token], calendars) }) do
      config = { 'trakt' => { 'account_id' => 'acc', 'client_id' => 'id', 'client_secret' => 'secret' } }
      trakt_client = Struct.new(:token).new({ access_token: 'stored-token' })
      app = Struct.new(:config, :db, :trakt).new(config, @db, trakt_client)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

      service.refresh(date_range: date_range, limit: 10, sources: ['trakt'])
    end

    assert_equal [[:movies, start_date, days], [:shows, start_date, days]], calendars.calls
    assert_equal({ access_token: 'stored-token' }, fetcher_instance.token)
  end

  def test_trakt_movies_rejects_non_hash_items
    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker)
    payload = [
      {
        'released' => Date.today.to_s,
        'movie' => { 'title' => 'Valid Movie', 'ids' => { 'slug' => 'valid-movie' } }
      },
      nil
    ]

    entries, error = service.send(:parse_trakt_movies, payload)

    assert_empty entries
    assert_equal 'Invalid Trakt payload format', error

    error = @speaker.messages.find { |message| message.is_a?(Array) && message.first == :error }
    assert_includes error&.last.to_s, 'Calendar Trakt movies payload'
  end

  def test_trakt_shows_skip_invalid_show_records
    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker)
    payload = [
      {
        'first_aired' => Date.today.to_s,
        'show' => []
      }
    ]

    entries, error = service.send(:parse_trakt_shows, payload)

    assert_empty entries
    assert_nil error
  end

  def test_trakt_payload_missing_is_reported
    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker)

    entries, error = service.send(:parse_trakt_movies, nil)

    assert_empty entries
    assert_equal 'Trakt payload missing or empty', error

    error_message = @speaker.messages.find { |message| message.is_a?(Array) && message.first == :error }
    assert_includes error_message&.last.to_s, 'Calendar Trakt movies payload'
  end

  def test_trakt_provider_surfaces_validation_errors
    provider = MediaLibrarian::Services::CalendarFeedService::TraktCalendarProvider.new(
      account_id: 'acc', client_id: 'id', client_secret: 'secret', speaker: @speaker,
      fetcher: ->(**_) { { entries: [], errors: ['Trakt payload missing or empty'] } }
    )

    provider.send(:fetch_entries, Date.today..Date.today, 5)

    error_message = @speaker.messages.find { |message| message.is_a?(Array) && message.first == :error }
    assert_includes error_message&.last.to_s, 'Calendar Trakt fetch failed'
  end

  def test_trakt_provider_requires_account_id
    provider = MediaLibrarian::Services::CalendarFeedService::TraktCalendarProvider.new(
      account_id: '', client_id: 'id', client_secret: 'secret', speaker: @speaker,
      fetcher: ->(**_) { { entries: [], errors: [] } }
    )

    result = provider.send(:fetch_entries, Date.today..Date.today, 5)

    assert_empty result
    error_message = @speaker.messages.find { |message| message.is_a?(Array) && message.first == :error }
    assert_includes error_message&.last.to_s, 'Trakt account_id is required'
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

  def test_tmdb_fetch_page_uses_http_fallback_for_discover_paths
    client = Module.new
    provider = MediaLibrarian::Services::CalendarFeedService::TmdbCalendarProvider.new(
      api_key: '123', language: 'en', region: 'US', speaker: @speaker, client: client
    )

    query = { page: 1, 'primary_release_date.gte' => Date.today.to_s }
    calls = []

    provider.stub(:http_request, ->(path, params) { calls << [path, params]; { 'results' => [] } }) do
      provider.send(:fetch_page, '/discover/movie', :movie, 1, query.dup)
    end

    assert_equal [['/discover/movie', query]], calls
  end

  def test_tmdb_fetch_titles_accepts_array_payloads_without_total_pages
    client = Module.new do
      movie_mod = Module.new do
        class << self
          attr_accessor :detail_calls
        end

        def self.upcoming
          [
            { 'id' => 10, 'release_date' => (Date.today + 1).to_s },
            { 'id' => 11, 'release_date' => (Date.today + 2).to_s }
          ]
        end

        def self.detail(id)
          self.detail_calls ||= []
          self.detail_calls << id
          {
            'id' => id,
            'title' => "Array Movie #{id}",
            'genres' => [],
            'languages' => [],
            'spoken_languages' => [],
            'origin_country' => [],
            'production_countries' => [],
            'vote_count' => id * 10,
            'imdb_id' => format('tt%07d', id)
          }
        end
      end

      const_set(:Movie, movie_mod)
    end

    provider = MediaLibrarian::Services::CalendarFeedService::TmdbCalendarProvider.new(
      api_key: '123', language: 'en', region: 'US', speaker: @speaker, client: client
    )

    date_range = Date.today..(Date.today + 7)
    results = provider.send(:fetch_titles, '/movie/upcoming', :movie, date_range, 10)

    assert_equal ['Array Movie 10', 'Array Movie 11'], results.map { |entry| entry[:title] }
    assert_equal [10, 11], client::Movie.detail_calls
    assert_equal(
      [{ 'tmdb' => 10, 'imdb' => 'tt0000010' }, { 'tmdb' => 11, 'imdb' => 'tt0000011' }],
      results.map { |entry| entry[:ids] }
    )
    assert_equal [100, 110], results.map { |entry| entry[:imdb_votes] }
  end

  def test_tmdb_fetch_titles_accepts_tmdb_model_objects
    client = Module.new do
      movie_mod = Module.new do
        class << self
          attr_accessor :detail_calls
        end

        def self.upcoming
          [Struct.new(:id, :release_date).new(21, (Date.today + 1).to_s)]
        end

        def self.detail(id)
          self.detail_calls ||= []
          self.detail_calls << id
          {
            'id' => id,
            'title' => "Object Movie #{id}",
            'genres' => [],
            'languages' => [],
            'spoken_languages' => [],
            'origin_country' => [],
            'production_countries' => [],
            'vote_count' => id + 1,
            'imdb_id' => format('tt%07d', id)
          }
        end
      end

      tv_mod = Module.new do
        class << self
          attr_accessor :detail_calls
        end

        def self.on_the_air
          [Struct.new(:id, :first_air_date).new(31, (Date.today + 2).to_s)]
        end

        def self.detail(id)
          self.detail_calls ||= []
          self.detail_calls << id
          {
            'id' => id,
            'name' => "Object Show #{id}",
            'genres' => [],
            'languages' => [],
            'spoken_languages' => [],
            'origin_country' => [],
            'production_countries' => [],
            'vote_count' => id + 2,
            'imdb_id' => format('tt%07d', id)
          }
        end
      end

      const_set(:Movie, movie_mod)
      const_set(:TV, tv_mod)
    end

    provider = MediaLibrarian::Services::CalendarFeedService::TmdbCalendarProvider.new(
      api_key: '123', language: 'en', region: 'US', speaker: @speaker, client: client
    )

    date_range = Date.today..(Date.today + 7)
    results = provider.upcoming(date_range: date_range, limit: 10)

    assert_equal ['Object Movie 21', 'Object Show 31'], results.map { |entry| entry[:title] }
    assert_equal [21], client::Movie.detail_calls
    assert_equal [31], client::TV.detail_calls
    assert_equal(
      [{ 'tmdb' => 21, 'imdb' => 'tt0000021' }, { 'tmdb' => 31, 'imdb' => 'tt0000031' }],
      results.map { |entry| entry[:ids] }
    )
    assert_equal [22, 33], results.map { |entry| entry[:imdb_votes] }
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
      imdb_votes: 321,
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
      Text :ids
      String :poster_url, size: 500
      String :backdrop_url, size: 500
      Integer :imdb_votes
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

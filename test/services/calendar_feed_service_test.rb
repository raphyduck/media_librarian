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

  def test_refresh_accepts_entries_without_external_ids_when_imdb_present
    imdb_id = 'tt9000001'
    provider = FakeProvider.new([
      base_entry.merge(external_id: nil, imdb_id: imdb_id, ids: { 'imdb' => imdb_id }, title: 'IMDb Only')
    ])

    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db, providers: [provider])

    service.refresh(date_range: Date.today..(Date.today + 5), limit: 10)

    row = @db.get_rows(:calendar_entries).first
    assert_equal imdb_id, row[:external_id]
    assert_equal imdb_id, row[:imdb_id]
    assert_equal 'IMDb Only', row[:title]
  end

  def test_refresh_deduplicates_entries_by_imdb_id
    imdb_id = 'tt9000002'
    provider = FakeProvider.new([
      base_entry.merge(external_id: 'first', imdb_id: imdb_id, ids: { 'imdb' => imdb_id }, title: 'First'),
      base_entry.merge(external_id: 'second', imdb_id: imdb_id, ids: { 'imdb' => imdb_id }, title: 'Second')
    ])

    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db, providers: [provider])

    service.refresh(date_range: Date.today..(Date.today + 5), limit: 10)

    rows = @db.get_rows(:calendar_entries)
    assert_equal 1, rows.count
    assert_equal 'first', rows.first[:external_id]
    assert_equal 'First', rows.first[:title]
  end

  def test_enriches_tmdb_entries_with_omdb_details
    entry = base_entry.merge(
      source: 'tmdb',
      ids: { 'imdb' => 'tt0111161' },
      rating: nil,
      imdb_votes: nil,
      poster_url: nil,
      backdrop_url: nil,
      genres: [],
      languages: [],
      countries: [],
      release_date: nil
    )
    provider = FakeProvider.new([entry])
    omdb_client = Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def title(id)
        @calls << id
        {
          rating: 9.3,
          imdb_votes: 234_567,
          poster_url: 'https://omdb.test/poster.jpg',
          backdrop_url: 'https://omdb.test/backdrop.jpg',
          genres: ['Drama'],
          languages: ['fr'],
          countries: ['FR'],
          release_date: Date.new(2025, 12, 31)
        }
      end
    end.new

    OmdbApi.stub :new, ->(**_) { omdb_client } do
      config = { 'omdb' => { 'api_key' => 'omdb-key' } }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker, db: @db, providers: [provider])

      service.refresh(date_range: Date.today..(Date.today + 2), limit: 5)
    end

    row = @db.get_rows(:calendar_entries, { source: 'tmdb' }).first
    assert_in_delta 9.3, row[:rating]
    assert_equal 234_567, row[:imdb_votes]
    assert_equal 'https://omdb.test/poster.jpg', row[:poster_url]
    assert_equal 'https://omdb.test/backdrop.jpg', row[:backdrop_url]
    assert_equal ['Drama'], row[:genres]
    assert_equal ['fr'], row[:languages]
    assert_equal ['FR'], row[:countries]
    assert_equal Date.new(2025, 12, 31).to_s, row[:release_date]
  end

  def test_rejects_tmdb_entries_without_imdb_ids
    entry = base_entry.merge(
      source: 'tmdb',
      imdb_id: nil,
      ids: { 'tmdb' => 42 },
      rating: nil,
      imdb_votes: nil,
      poster_url: nil,
      backdrop_url: nil
    )
    provider = FakeProvider.new([entry])
    omdb_client = Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def title(id)
        @calls << [:title, id]
        { rating: 9.0, imdb_votes: 999_999 }
      end

      def find_by_title(title:, year: nil, type: nil)
        @calls << [:find_by_title, title, year, type]
        { rating: 8.4, imdb_votes: 111_222, poster_url: 'https://omdb.test/poster.jpg', ids: { 'imdb' => 'tt0000042' } }
      end
    end.new

    OmdbApi.stub :new, ->(**_) { omdb_client } do
      config = { 'omdb' => { 'api_key' => 'omdb-key' } }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker, db: @db, providers: [provider])

      service.refresh(date_range: Date.today..(Date.today + 2), limit: 5)
    end

    assert_empty omdb_client.calls
    assert_empty @db.get_rows(:calendar_entries, { source: 'tmdb' })
  end

  def test_omdb_enrichment_verifies_titles_before_applying_details
    entry = base_entry.merge(
      title: 'Destination jeu. 25 déc.',
      imdb_id: 'tt9619824',
      ids: { 'imdb' => 'tt9619824' },
      release_date: Date.today + 1,
      rating: nil,
      imdb_votes: nil,
      poster_url: nil
    )
    provider = FakeProvider.new([entry])

    omdb_client = Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def title(id)
        @calls << [:title, id]
        { title: 'Final Destination: Bloodlines', release_date: Date.new(2026, 1, 1), rating: 1.1 }
      end

      def find_by_title(title:, year:, type: nil)
        @calls << [:find_by_title, title, year, type]
        { title: 'Destination', release_date: Date.new(year, 12, 25), rating: 8.2, ids: { 'imdb' => 'tt1234567' } }
      end
    end.new

    OmdbApi.stub :new, ->(**_) { omdb_client } do
      config = { 'omdb' => { 'api_key' => 'omdb-key' } }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker, db: @db, providers: [provider])

      service.refresh(date_range: Date.today..(Date.today + 2), limit: 5)
    end

    row = @db.get_rows(:calendar_entries, { source: 'fake' }).first
    assert_includes omdb_client.calls, [:title, 'tt9619824']
    assert_includes omdb_client.calls, [:find_by_title, 'Destination jeu. 25 déc.', entry[:release_date].year, 'movie']
    assert_in_delta 8.2, row[:rating]
    assert_equal 'tt1234567', row[:ids][:imdb]
  end

  def test_omdb_enrichment_fixes_title_when_it_is_an_imdb_id
    entry = base_entry.merge(
      title: 'tt0453467',
      imdb_id: 'tt0453467',
      ids: { 'imdb' => 'tt0453467' },
      release_date: Date.today + 1,
      rating: nil,
      imdb_votes: nil
    )
    provider = FakeProvider.new([entry])

    omdb_client = Class.new do
      def title(_id)
        { title: 'Déjà Vu', release_date: Date.new(2006, 11, 22), rating: 7.1,
          ids: { 'imdb' => 'tt0453467' }, imdb_votes: 343_761 }
      end

      def find_by_title(title:, year:, type: nil)
        nil
      end
    end.new

    OmdbApi.stub :new, ->(**_) { omdb_client } do
      config = { 'omdb' => { 'api_key' => 'omdb-key' } }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker, db: @db, providers: [provider])
      service.refresh(date_range: Date.today..(Date.today + 2), limit: 5)
    end

    row = @db.get_rows(:calendar_entries).first
    assert_equal 'Déjà Vu', row[:title]
    assert_in_delta 7.1, row[:rating]
  end

  def test_omdb_search_uses_series_type_for_shows
    entry = base_entry.merge(media_type: 'show')
    provider = FakeProvider.new([entry])
    omdb_client = Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def title(id)
        @calls << [:title, id]
        nil
      end

      def find_by_title(title:, year:, type: nil)
        @calls << [:find_by_title, title, year, type]
        { title: title, ids: { 'imdb' => 'tt9999999' } }
      end
    end.new

    OmdbApi.stub :new, ->(**_) { omdb_client } do
      config = { 'omdb' => { 'api_key' => 'omdb-key' } }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker, db: @db, providers: [provider])

      service.refresh(date_range: Date.today..(Date.today + 2), limit: 5)
    end

    assert_includes omdb_client.calls, [:find_by_title, entry[:title], entry[:release_date].year, 'series']
  end

  def test_skips_enrichment_when_omdb_disabled
    entry = base_entry.merge(source: 'tmdb', ids: { 'imdb' => 'tt7654321' }, rating: nil, imdb_votes: nil)
    provider = FakeProvider.new([entry])

    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db, providers: [provider])

    service.refresh(date_range: Date.today..(Date.today + 1), limit: 3)

    row = @db.get_rows(:calendar_entries).first
    assert_nil row[:rating]
    assert_nil row[:imdb_votes]
  end

  def test_rejects_trakt_entries_without_imdb_ids
    entry = base_entry.merge(
      source: 'trakt',
      imdb_id: nil,
      ids: { 'tmdb' => 7 },
      rating: nil,
      imdb_votes: nil,
      poster_url: nil,
      backdrop_url: nil
    )
    provider = FakeProvider.new([entry])
    omdb_client = Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def title(id)
        @calls << [:title, id]
        { rating: 9.9, imdb_votes: 1 }
      end

      def find_by_title(title:, year: nil, type: nil)
        @calls << [:find_by_title, title, year, type]
        { rating: 7.5, imdb_votes: 22_333, poster_url: 'https://omdb.test/poster.jpg', ids: { 'imdb' => 'tt0000007' } }
      end
    end.new

    OmdbApi.stub :new, ->(**_) { omdb_client } do
      config = { 'omdb' => { 'api_key' => 'omdb-key' } }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker, db: @db, providers: [provider])

      service.refresh(date_range: Date.today..(Date.today + 2), limit: 5)
    end

    assert_empty omdb_client.calls
    assert_empty @db.get_rows(:calendar_entries, { source: 'trakt' })
  end

  def test_enrichment_debug_logs_when_omdb_returns_nothing
    entry = base_entry.merge(source: 'tmdb', ids: { 'tmdb' => 8 }, rating: nil, imdb_votes: nil, poster_url: nil)
    provider = FakeProvider.new([entry])

    omdb_client = Class.new do
      attr_reader :last_request_path, :last_response_body, :calls

      def initialize
        @calls = []
        @last_request_path = 'https://omdb.test/?apikey=debug'
        @last_response_body = 'x' * 250
      end

      def title(id)
        @calls << [:title, id]
        nil
      end

      def find_by_title(title:, year: nil, type: nil)
        @calls << [:find_by_title, title, year, type]
        @last_request_path = 'https://omdb.test/search'
        @last_response_body = 'y' * 250
        nil
      end
    end.new

    Env.stub :debug?, ->(*) { true } do
      OmdbApi.stub :new, ->(**_) { omdb_client } do
        config = { 'omdb' => { 'api_key' => 'omdb-key' } }
        app = Struct.new(:config, :db).new(config, @db)
        service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker, db: @db, providers: [provider])

        service.refresh(date_range: Date.today..(Date.today + 2), limit: 5)
      end
    end

    assert @speaker.messages.any? { |msg| msg.include?('OMDb enrichment searching by title for Base') }
    truncated_payload = "#{'y' * 200}...[truncated]"
    assert @speaker.messages.any? do |msg|
      msg.include?('OMDb enrichment missing for Base') && msg.include?(truncated_payload)
    end
  end

  def test_enrichment_skips_entries_when_omdb_json_is_invalid
    invalid_body = '{"Title":"Incomplete"'
    fake_client = Class.new do
      def get(*)
        Struct.new(:code, :body).new(200, invalid_body)
      end

      define_method(:invalid_body) { invalid_body }
    end.new

    api = OmdbApi.allocate
    api.send(:initialize, api_key: 'omdb-key', http_client: fake_client, speaker: @speaker)

    assert_nil api.send(:parse_json, invalid_body, 200, :calendar)

    entry = base_entry.merge(source: 'tmdb', ids: { 'imdb' => 'tt7654321' }, rating: nil, imdb_votes: nil, poster_url: nil)
    provider = FakeProvider.new([entry])

    OmdbApi.stub :new, ->(**_) { api } do
      config = { 'omdb' => { 'api_key' => 'omdb-key' } }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker, db: @db, providers: [provider])

      service.refresh(date_range: Date.today..(Date.today + 2), limit: 5)
    end

    row = @db.get_rows(:calendar_entries, { source: 'tmdb' }).first
    assert_nil row[:rating]
    assert_nil row[:imdb_votes]
    assert_equal 'tt7654321', row[:ids][:imdb]
  end

  def test_enrichment_logs_errors_and_falls_back
    entry = base_entry.merge(source: 'tmdb', ids: { 'imdb' => 'tt0123456' }, rating: 6.5, imdb_votes: 100)
    provider = FakeProvider.new([entry])
    omdb_client = Class.new do
      def title(_id)
        raise StandardError, 'omdb detail failed'
      end
    end.new

    OmdbApi.stub :new, ->(**_) { omdb_client } do
      config = { 'omdb' => { 'api_key' => 'omdb-key' } }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker, db: @db, providers: [provider])

      service.refresh(date_range: Date.today..(Date.today + 1), limit: 2)
    end

    row = @db.get_rows(:calendar_entries).first
    assert_in_delta 6.5, row[:rating]
    assert_equal 100, row[:imdb_votes]
    assert @speaker.messages.any? { |msg| msg.is_a?(Array) && msg.last == 'Calendar OMDb enrichment failed' }
  end

  def test_filters_out_movies_without_imdb_match
    entry = base_entry.merge(source: 'tmdb', imdb_id: nil, ids: { 'tmdb' => 9 }, rating: nil, imdb_votes: nil, poster_url: nil)
    provider = FakeProvider.new([entry], source: 'tmdb')

    omdb_client = Class.new do
      def title(*) = nil

      def find_by_title(**)
        nil
      end
    end.new

    OmdbApi.stub :new, ->(**_) { omdb_client } do
      config = { 'omdb' => { 'api_key' => 'omdb-key' } }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker, db: @db, providers: [provider])

      results = service.refresh(date_range: Date.today..(Date.today + 2), limit: 5)
      assert_empty results
    end

    assert_empty @db.get_rows(:calendar_entries)
    assert @speaker.messages.any? { |msg| msg.start_with?('Calendar feed persisted 0 items (tmdb: 0)') }
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
    imdb_id = 'tt9100001'
    initial_provider = FakeProvider.new([
      base_entry.merge(external_id: 'movie-1', imdb_id: imdb_id, ids: { 'imdb' => imdb_id }, title: 'First Title', rating: 6.4,
                        imdb_votes: 10)
    ])
    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db, providers: [initial_provider])
    service.refresh(date_range: Date.today..(Date.today + 3), limit: 5)

    updated_provider = FakeProvider.new([
      base_entry.merge(external_id: 'movie-1', imdb_id: imdb_id, ids: { 'imdb' => imdb_id }, title: 'First Title', rating: 8.2,
                        languages: ['fr'], imdb_votes: 12)
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
      'trakt' => { 'account_id' => 'acc', 'client_id' => 'id', 'client_secret' => 'secret' }
    }
    app = Struct.new(:config, :db).new(config, @db)

    service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

    sources = service.send(:default_providers).map(&:source)
    assert_includes sources, 'tmdb'
    refute_includes sources, 'omdb'
    assert_includes sources, 'trakt'
  end

  def test_normalization_downcases_sources
    date = Date.today + 1
    tmdb_provider = FakeProvider.new([
      base_entry.merge(source: 'TMDB', external_id: 'tmdb-1', imdb_id: 'tt1000001',
                       ids: { 'imdb' => 'tt1000001' }, title: 'TMDB Title')
    ], source: 'TMDB')
    omdb_provider = MediaLibrarian::Services::CalendarFeedService::OmdbCalendarProvider.new(
      speaker: @speaker,
      api_key: 'key',
      fetcher: ->(**_) {
                  [{ external_id: 'tt1000002', imdb_id: 'tt1000002', ids: { 'imdb' => 'tt1000002' }, title: 'OMDb Title',
 media_type: 'movie', release_date: date }]
                }
    )
    trakt_provider = MediaLibrarian::Services::CalendarFeedService::TraktCalendarProvider.new(
      account_id: 'acc', client_id: 'id', client_secret: 'secret', speaker: @speaker,
      fetcher: ->(**_) {
                  [{ external_id: 'trakt-1', imdb_id: 'tt1000003', ids: { 'imdb' => 'tt1000003' }, title: 'Trakt Title',
 media_type: 'show', release_date: date }]
                }
    )

    service = MediaLibrarian::Services::CalendarFeedService.new(
      app: nil,
      speaker: @speaker,
      db: @db,
      providers: [tmdb_provider, omdb_provider, trakt_provider]
    )

    service.refresh(date_range: Date.today..(Date.today + 3), limit: 10)

    rows = @db.get_rows(:calendar_entries).sort_by { |row| row[:external_id] }
    assert_equal %w[omdb tmdb trakt], rows.map { |row| row[:source] }.uniq.sort
    assert_equal %w[movie movie show].sort, rows.map { |row| row[:media_type] }.sort
  end

  def test_omdb_provider_fetches_via_omdb_api_helper
    movie_date = Date.today + 1
    show_date = Date.today + 2
    date_range = Date.today..(Date.today + 5)
    year_only = Date.today.year
    calendar_items = [
      {
        'imdbID' => 'tt0111161',
        'Title' => 'The Shawshank Redemption',
        'Type' => 'movie',
        'Released' => movie_date,
        'Genre' => 'Drama',
        'Language' => 'English',
        'Country' => 'United States',
        'imdbRating' => '9.3',
        'imdbVotes' => '123,456'
      },
      {
        'imdbID' => 'tt7654321',
        'Title' => 'New Series',
        'Type' => 'series',
        'Released' => show_date,
        'Genre' => 'Sci-Fi',
        'Language' => 'French',
        'Country' => 'Canada',
        'imdbRating' => '7.5',
        'imdbVotes' => '6,789'
      },
      {
        'imdbID' => 'tt2024001',
        'Title' => 'Year Only Movie',
        'Type' => 'movie',
        'Year' => year_only
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

    OmdbApi.stub :new, ->(**_) { helper } do
      omdb_provider = MediaLibrarian::Services::CalendarFeedService::OmdbCalendarProvider.new(
        speaker: @speaker,
        api_key: 'omdb-key'
      )
      service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db, providers: [omdb_provider])

      service.refresh(date_range: date_range, limit: 5, sources: ['omdb'])
    end

    assert_equal [{ date_range: date_range, limit: 5 }], helper.calls
    rows = @db.get_rows(:calendar_entries, { source: 'omdb' }).sort_by { |row| row[:external_id] }
    assert_equal 3, rows.count
    assert_equal 'movie', rows.first[:media_type]
    assert_equal ['Drama'], rows.first[:genres]
    assert_equal ['English'], rows.first[:languages]
    assert_equal ['United States'], rows.first[:countries]
    assert_equal 123_456, rows.first[:imdb_votes]
    assert_equal 'movie', rows[1][:media_type]
    assert_equal date_range.first.to_s, rows[1][:release_date].to_s
    assert_equal 'show', rows.last[:media_type]
    assert_equal ['Sci-Fi'], rows.last[:genres]
    assert_equal ['French'], rows.last[:languages]
    assert_equal ['Canada'], rows.last[:countries]
    assert_equal 6_789, rows.last[:imdb_votes]
  end

  def test_omdb_fetcher_logs_calls_and_errors
    date_range = Date.today..(Date.today + 3)
    helper = Class.new do
      attr_reader :last_request_path

      def initialize
        @last_request_path = 'https://example.test/?apikey=omdb'
      end

      def calendar(**_args)
        raise StandardError, 'calendar exploded'
      end
    end.new

    OmdbApi.stub :new, ->(**_) { helper } do
      omdb_provider = MediaLibrarian::Services::CalendarFeedService::OmdbCalendarProvider.new(
        speaker: @speaker,
        api_key: 'key'
      )
      service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db, providers: [omdb_provider])

      service.refresh(date_range: date_range, limit: 2, sources: ['omdb'])
    end

    assert @speaker.messages.any? { |msg| msg.is_a?(Array) && msg.first == :error && msg[1].is_a?(StandardError) && msg.last == 'Calendar OMDb fetch failed' }
  end

  def test_omdb_provider_logs_empty_results
    date_range = Date.today..(Date.today + 1)
    omdb_provider = MediaLibrarian::Services::CalendarFeedService::OmdbCalendarProvider.new(
      speaker: @speaker,
      api_key: 'key',
      fetcher: ->(**_) { [] }
    )

    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db, providers: [omdb_provider])

    service.refresh(date_range: date_range, limit: 3, sources: ['omdb'])

    expected_message = "Calendar provider omdb returned no entries for #{date_range.first}..#{date_range.last}"
    assert_includes @speaker.messages, expected_message
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
          'ids' => { 'slug' => 'trakt-show', 'imdb' => 'tt8888888', 'tmdb' => 333, 'trakt' => 2222 },
          'genres' => ['sci-fi'],
          'language' => 'en',
          'country' => 'gb',
          'rating' => 8.1,
          'votes' => 75
        }
      }
    ]

    fetcher_instance = nil
    calendar = Class.new do
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

      def initialize(token, calendar, account_id)
        @token = token
        @calendar = calendar
        @account_id = account_id
      end

      def calendar
        @calendar
      end
    end

    Trakt.stub(:new, ->(opts) { fetcher_instance = fake_fetcher_class.new(opts[:token], calendar, opts[:account_id]) }) do
      config = { 'trakt' => { 'account_id' => 'acc', 'client_id' => 'id', 'client_secret' => 'secret', 'access_token' => 'tok' } }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

      service.refresh(date_range: date_range, limit: 10, sources: ['trakt'])
    end

    assert_equal [[:movies, start_date, days], [:shows, start_date, days]], calendar.calls
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

  def test_trakt_output_capture_uses_original_streams
    speaker = SimpleSpeaker::Speaker.new
    entry_date = Date.today + 1
    entry = base_entry.merge(source: 'trakt', external_id: 'trakt-1', title: 'Trakt Title', release_date: entry_date)

    service = nil
    fetcher = lambda do |**_|
      service.send(:with_trakt_output_capture) do
        puts 'Trakt output'
        { entries: [entry], errors: [] }
      end
    end

    provider = MediaLibrarian::Services::CalendarFeedService::TraktCalendarProvider.new(
      account_id: 'acc', client_id: 'cid', client_secret: 'secret', speaker: speaker, fetcher: fetcher
    )

    service = MediaLibrarian::Services::CalendarFeedService.new(
      app: nil,
      speaker: speaker,
      db: @db,
      providers: [provider]
    )

    service.refresh(date_range: Date.today..(Date.today + 3), limit: 5, sources: ['trakt'])

    rows = @db.get_rows(:calendar_entries, { source: 'trakt' })
    assert_equal 1, rows.count
    assert_equal 'Trakt Title', rows.first[:title]
  end

  def test_trakt_fetcher_uses_fallback_calendar_client_when_primary_returns_nil
    start_date = Date.today
    end_date = start_date + 1
    date_range = start_date..end_date
    token = { access_token: 'token', expires_at: Time.now + 3600 }

    calendar_client = Object.new
    trakt_client = Class.new do
      attr_reader :calendar_called

      def initialize(calendar_client)
        @calendar_client = calendar_client
        @calendar_called = false
      end

      def calendar
        @calendar_called = true
        @calendar_client
      end
    end.new(calendar_client)

    movie_payload = [
      { 'released' => start_date.to_s, 'movie' => { 'title' => 'Fallback Movie', 'ids' => { 'slug' => 'fb-movie' } } }
    ]
    show_payload = [
      { 'first_aired' => end_date.to_s, 'show' => { 'title' => 'Fallback Show', 'ids' => { 'slug' => 'fb-show' } } }
    ]

    call_log = []
    TraktAgent.stub(:fetch_calendar_entries, ->(type, _start, _days, fetcher:) do
      call_log << [type, fetcher]
      next nil if fetcher.equal?(trakt_client)

      type == :movies ? movie_payload : show_payload
    end) do
      service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db)
      service.stub(:trakt_calendar_client, ->(**_) { trakt_client }) do
        result = service.send(
          :fetch_trakt_entries,
          date_range: date_range,
          limit: 10,
          client_id: 'id',
          client_secret: 'secret',
          account_id: 'acc',
          token: token
        )

        assert_equal 2, result[:entries].size
        assert_empty result[:errors]
      end
    end

    assert_equal [[:movies, trakt_client], [:movies, calendar_client], [:shows, trakt_client], [:shows, calendar_client]], call_log
    assert trakt_client.calendar_called
  end

  def test_trakt_fetcher_uses_app_token_when_config_token_missing
    date_range = Date.today..(Date.today + 1)
    start_date = date_range.first
    days = (date_range.last - start_date).to_i + 1

    calendar = Class.new do
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

      def initialize(token, calendar)
        @token = token
        @calendar = calendar
      end

      def calendar
        @calendar
      end
    end

    Trakt.stub(:new, ->(opts) { fetcher_instance = fake_fetcher_class.new(opts[:token], calendar) }) do
      config = { 'trakt' => { 'account_id' => 'acc', 'client_id' => 'id', 'client_secret' => 'secret' } }
      trakt_client = Struct.new(:token).new({ access_token: 'stored-token' })
      app = Struct.new(:config, :db, :trakt).new(config, @db, trakt_client)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

      service.refresh(date_range: date_range, limit: 10, sources: ['trakt'])
    end

    assert_equal [[:movies, start_date, days], [:shows, start_date, days]], calendar.calls
    assert_equal({ access_token: 'stored-token' }, fetcher_instance.token)
  end

  def test_trakt_fetcher_aggregates_chunks
    start_date = Date.new(2024, 1, 1)
    end_date = start_date + 3
    date_range = start_date..end_date
    token = { access_token: 'token', expires_at: Time.now + 3600 }

    call_log = []
    movies_payloads = [
      [{ 'released' => start_date.to_s, 'movie' => { 'title' => 'Movie 1', 'ids' => { 'slug' => 'movie-1' } } }],
      [{ 'released' => (start_date + 2).to_s, 'movie' => { 'title' => 'Movie 2', 'ids' => { 'slug' => 'movie-2' } } }]
    ]
    shows_payloads = [
      [{ 'first_aired' => (start_date + 1).to_s, 'show' => { 'title' => 'Show 1', 'ids' => { 'slug' => 'show-1' } } }],
      [{ 'first_aired' => (start_date + 3).to_s, 'show' => { 'title' => 'Show 2', 'ids' => { 'slug' => 'show-2' } } }]
    ]

    TraktAgent.stub(:fetch_calendar_entries, ->(type, _start, _days, fetcher:) do
      call_log << [type, _start, _days, fetcher]
      type == :movies ? movies_payloads.shift : shows_payloads.shift
    end) do
      service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db)

      service.stub(:trakt_calendar_client, ->(**_) { :client }) do
        service.stub(:trakt_calendar_chunk_days, 2) do
          result = service.send(
            :fetch_trakt_entries,
            date_range: date_range,
            limit: 10,
            client_id: 'id',
            client_secret: 'secret',
            account_id: 'acc',
            token: token
          )

          assert_equal %w[movie-1 movie-2 show-1 show-2].sort, result[:entries].map { |e| e[:external_id] }.sort
          assert_empty result[:errors]
        end
      end
    end

    assert_equal(
      [
        [:movies, start_date, 2, :client],
        [:shows, start_date, 2, :client],
        [:movies, start_date + 2, 2, :client],
        [:shows, start_date + 2, 2, :client]
      ],
      call_log
    )
  end

  def test_trakt_fetcher_respects_limit_across_chunks
    start_date = Date.new(2024, 2, 1)
    end_date = start_date + 3
    date_range = start_date..end_date
    token = { access_token: 'token', expires_at: Time.now + 3600 }

    TraktAgent.stub(:fetch_calendar_entries, ->(type, *_args, **) do
      if type == :movies
        [
          { 'released' => start_date.to_s, 'movie' => { 'title' => 'Movie 1', 'ids' => { 'slug' => 'movie-1' } } },
          { 'released' => start_date.to_s, 'movie' => { 'title' => 'Movie 1', 'ids' => { 'slug' => 'movie-1' } } }
        ]
      else
        []
      end
    end) do
      service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker, db: @db)

      service.stub(:trakt_calendar_client, ->(**_) { :client }) do
        service.stub(:trakt_calendar_chunk_days, 2) do
          result = service.send(
            :fetch_trakt_entries,
            date_range: date_range,
            limit: 1,
            client_id: 'id',
            client_secret: 'secret',
            account_id: 'acc',
            token: token
          )

          assert_equal 1, result[:entries].size
          assert_equal 'movie-1', result[:entries].first[:external_id]
        end
      end
    end
  end

  def test_trakt_movies_filter_invalid_items_but_keep_valid
    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker)
    payload = [
      {
        'released' => Date.today.to_s,
        'movie' => { 'title' => 'Valid Movie', 'ids' => { 'slug' => 'valid-movie' } }
      },
      nil
    ]

    entries, error = service.send(:parse_trakt_movies, payload)

    assert_equal 1, entries.size
    assert_nil error

    error = @speaker.messages.find { |message| message.is_a?(Array) && message.first == :error }
    assert_includes error&.last.to_s, 'Calendar Trakt movies payload'
  end

  def test_trakt_shows_filter_invalid_items_but_keep_valid
    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker)
    payload = [
      {
        'first_aired' => Date.today.to_s,
        'show' => { 'title' => 'Valid Show', 'ids' => { 'slug' => 'valid-show' } }
      },
      'invalid'
    ]

    entries, error = service.send(:parse_trakt_shows, payload)

    assert_equal 1, entries.size
    assert_nil error

    error = @speaker.messages.find { |message| message.is_a?(Array) && message.first == :error }
    assert_includes error&.last.to_s, 'Calendar Trakt shows payload'
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

  def test_trakt_parsers_handle_struct_payloads
    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker)

    movie_struct = Struct.new(:title, :ids).new('Struct Movie', { slug: 'struct-movie' })
    movie_payload = [Struct.new(:released, :movie).new(Date.today.to_s, movie_struct)]

    show_struct = Struct.new(:title, :ids).new('Struct Show', { slug: 'struct-show' })
    episode_struct = Struct.new(:first_aired).new(Date.today.to_s)
    show_payload = [Struct.new(:first_aired, :show, :episode).new(nil, show_struct, episode_struct)]

    movie_entries, movie_error = service.send(:parse_trakt_movies, movie_payload)
    show_entries, show_error = service.send(:parse_trakt_shows, show_payload)

    assert_nil movie_error
    assert_nil show_error
    assert_equal 'struct-movie', movie_entries.first[:ids]['slug']
    assert_equal 'struct-show', show_entries.first[:ids]['slug']
  end

  def test_trakt_payload_missing_is_reported
    service = MediaLibrarian::Services::CalendarFeedService.new(app: nil, speaker: @speaker)

    entries, error = service.send(:parse_trakt_movies, nil)

    assert_empty entries
    assert_equal 'Trakt payload missing or empty', error

    error_message = @speaker.messages.find { |message| message.is_a?(Array) && message.first == :error }
    assert_includes error_message&.last.to_s, 'Calendar Trakt movies payload'
  end

  def test_trakt_provider_reports_missing_token_instead_of_empty_payload
    date_range = Date.today..Date.today
    config = { 'trakt' => { 'account_id' => 'acc', 'client_id' => 'id', 'client_secret' => 'secret', 'access_token' => '' } }

    Trakt.stub(:new, ->(*) { raise 'Trakt client should not initialize without token' }) do
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

      service.refresh(date_range: date_range, limit: 5, sources: ['trakt'])
    end

    error_messages = @speaker.messages.select { |message| message.is_a?(Array) && message.first == :error }
    assert error_messages.any? { |message| message[1].message.include?('Trakt access token is missing or invalid') }
    refute error_messages.any? { |message| message[1].message.include?('Trakt payload missing or empty') }
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

        def self.detail(id, **_opts)
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

        def self.detail(id, **_opts)
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

        def self.detail(id, **_opts)
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
    @base_index = (@base_index || 0) + 1
    imdb_id = format('tt%07d', @base_index)

    {
      source: 'fake',
      external_id: "base-id-#{@base_index}",
      imdb_id: imdb_id,
      title: 'Base',
      media_type: 'movie',
      genres: [],
      languages: ['en'],
      countries: ['US'],
      rating: 7.1,
      imdb_votes: 321,
      poster_url: 'https://example.test/poster.jpg',
      backdrop_url: 'https://example.test/backdrop.jpg',
      release_date: Date.today + 1,
      ids: { 'imdb' => imdb_id }
    }
  end

  def ensure_calendar_table
    return if @db.database.table_exists?(:calendar_entries)

    @db.database.create_table :calendar_entries do
      primary_key :id
      String :source, size: 50, null: false
      String :external_id, size: 200, null: false
      String :imdb_id, size: 50, null: false
      String :title, size: 500, null: false
      String :media_type, size: 50, null: false
      Text :genres
      Text :languages
      Text :countries
      Text :synopsis
      Text :ids
      String :poster_url, size: 500
      String :backdrop_url, size: 500
      Integer :imdb_votes
      Float :rating
      Date :release_date
      DateTime :created_at
      DateTime :updated_at

      index :imdb_id, unique: true
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

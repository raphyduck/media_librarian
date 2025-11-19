# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'date'

require_relative 'service_test_helper'
require_relative '../../app/media_librarian/services/base_service'
require_relative '../../app/media_librarian/services/calendar_feed_service'
require_relative '../../lib/storage/db'

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
      'imdb' => { 'user' => 'user', 'list' => 'watchlist' },
      'trakt' => { 'client_id' => 'id', 'client_secret' => 'secret' }
    }
    app = Struct.new(:config, :db).new(config, @db)

    service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

    sources = service.send(:default_providers).map(&:source)
    assert_includes sources, 'tmdb'
    assert_includes sources, 'imdb'
    assert_includes sources, 'trakt'
  end

  def test_normalization_downcases_sources
    date = Date.today + 1
    tmdb_provider = FakeProvider.new([
      base_entry.merge(source: 'TMDB', external_id: 'tmdb-1', title: 'TMDB Title')
    ], source: 'TMDB')
    imdb_provider = MediaLibrarian::Services::CalendarFeedService::ImdbCalendarProvider.new(
      user: 'user', list: 'list', speaker: @speaker,
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

  def test_imdb_provider_fetches_remote_list
    csv = <<~CSV
      position,const,created,modified,description,Title,Title type,Directors,You rated,IMDb Rating,Runtime (mins),Year,Genres,Num Votes,Release Date (month/day/year),URL
      1,tt0111161,2020-01-01,2020-01-01,,The Shawshank Redemption,Feature Film,,,9.3,142,1994,Drama,1000,#{(Date.today + 1).strftime('%m/%d/%Y')},https://www.imdb.com/title/tt0111161/
    CSV
    requests = []
    imdb_response = http_ok(csv)

    Net::HTTP.stub(:get_response, ->(uri) { requests << uri.to_s; imdb_response }) do
      config = { 'imdb' => { 'user' => 'ur123', 'list' => 'ls456' } }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

      service.refresh(date_range: Date.today..(Date.today + 5), limit: 5, sources: ['imdb'])
    end

    refute_empty requests
    row = @db.get_rows(:calendar_entries, { source: 'imdb' }).first
    refute_nil row
    assert_equal 'tt0111161', row[:external_id]
    assert_equal 'movie', row[:media_type]
    assert_equal ['Drama'], row[:genres]
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

    movie_path = "/calendars/all/movies/#{start_date}/#{days}"
    show_path = "/calendars/all/shows/#{start_date}/#{days}"
    responses = {
      movie_path => http_ok(JSON.dump(movie_payload)),
      show_path => http_ok(JSON.dump(show_payload))
    }
    requests = []

    fake_http = Class.new do
      def initialize(responses, requests)
        @responses = responses
        @requests = requests
      end

      def request(req)
        @requests << req.path
        @responses.fetch(req.path)
      end
    end

    Net::HTTP.stub(:start, ->(host, port = nil, *args, **kwargs, &block) {
      raise "unexpected host #{host}" unless host == 'api.trakt.tv'

      block.call(fake_http.new(responses, requests))
    }) do
      config = { 'trakt' => { 'client_id' => 'id', 'client_secret' => 'secret' } }
      app = Struct.new(:config, :db).new(config, @db)
      service = MediaLibrarian::Services::CalendarFeedService.new(app: app, speaker: @speaker)

      service.refresh(date_range: date_range, limit: 10, sources: ['trakt'])
    end

    assert_equal [movie_path, show_path].sort, requests.sort
    rows = @db.get_rows(:calendar_entries, { source: 'trakt' })
    assert_equal 2, rows.count
    movie = rows.find { |row| row[:media_type] == 'movie' }
    show = rows.find { |row| row[:media_type] == 'show' }
    assert_equal ['drama'], movie[:genres]
    assert_equal ['en'], movie[:languages]
    assert_equal ['gb'], show[:countries]
    assert_equal ['sci-fi'], show[:genres]
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
      Float :rating
      Date :release_date
      DateTime :created_at
      DateTime :updated_at

      index %i[source external_id], unique: true
      index :release_date
    end
  end

  def http_ok(body)
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, body)
    response
  end
end

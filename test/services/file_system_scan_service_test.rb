# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

require_relative 'service_test_helper'
require_relative '../../lib/metadata'
require_relative '../../lib/media_librarian/services/file_system_scan_request'
require_relative '../../app/media_librarian/services/base_service'
require_relative '../../app/media_librarian/services/calendar_feed_service'
require_relative '../../app/media_librarian/services/file_system_scan_service'

class FileSystemScanServiceTest < Minitest::Test
  class RecordingDb
    attr_reader :rows, :deleted_rows, :updated_rows

    def initialize
      @rows = []
      @deleted_rows = []
      @updated_rows = []
      @next_id = 0
    end

    def insert_row(table, values, or_replace = 0)
      @next_id += 1
      rows << values.merge(table: table.to_sym, replace: or_replace, id: @next_id)
    end

    def get_rows(table, conditions = {}, _additionals = {})
      rows.select { |row| row[:table] == table.to_sym && matches?(row, conditions) }
    end

    def update_rows(table, values, conditions, _additionals = {})
      matched = get_rows(table, conditions)
      updated_rows << values.merge(table: table.to_sym)
      matched.each { |row| row.merge!(values) }
      matched.length
    end

    def delete_rows(table, conditions, *_)
      deleted_rows << conditions.merge(table: table.to_sym)
      rows.reject! { |row| row[:table] == table.to_sym && matches?(row, conditions) }
      1
    end

    def table_exists?(table)
      %i[calendar_entries local_media watchlist].include?(table.to_sym)
    end

    private

    def matches?(row, conditions)
      conditions.all? { |column, value| row[column.to_sym].to_s == value.to_s }
    end
  end

  def setup
    @tmp_dir = Dir.mktmpdir('scan-service')
    @file_path = File.join(@tmp_dir, 'Example (2021).mkv')
    File.write(@file_path, '')

    @speaker = TestSupport::Fakes::Speaker.new
    @db = RecordingDb.new
    @app = Struct.new(:db, :speaker).new(@db, @speaker)
    @service = MediaLibrarian::Services::FileSystemScanService.new(app: @app)
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir && Dir.exist?(@tmp_dir)
  end

  def test_reports_missing_root
    request = MediaLibrarian::Services::FileSystemScanRequest.new(root_path: '/missing/path')

    @service.scan(request)

    assert_includes @speaker.messages, 'Root path /missing/path not found'
  end

  def test_persists_detected_media
    movie = Struct.new(:ids, :year).new({ 'imdb' => 'tt1234567' }, 2021)
    request = MediaLibrarian::Services::FileSystemScanRequest.new(
      root_path: @tmp_dir,
      type: 'movies'
    )

    library = {
      'movieExample2021' => {
        type: 'movies',
        name: 'Example',
        full_name: 'Example (2021)',
        movie: movie,
        files: [{ name: @file_path }]
      }
    }

    MediaLibrarian::Services::CalendarFeedService.stub(:enrich_entries, ->(entries, **) { entries }) do
      Library.stub(:process_folder, library) { @service.scan(request) }
    end

    assert_equal 2, @db.rows.length

    calendar = @db.rows.find { |row| row[:table] == :calendar_entries }
    assert_equal 'tt1234567', calendar[:imdb_id]
    assert_equal 'movie', calendar[:media_type]

    local_media = @db.rows.find { |row| row[:table] == :local_media }
    assert_equal 'movie', local_media[:media_type]
    assert_equal 'tt1234567', local_media[:imdb_id]
    assert_equal @file_path, local_media[:local_path]
    assert_equal 1, local_media[:replace]
  end

  def test_maps_tv_folder_to_show_media_type
    show = Struct.new(:ids, :title).new({ 'imdb' => 'tt7654321' }, 'Example Show')
    request = MediaLibrarian::Services::FileSystemScanRequest.new(
      root_path: @tmp_dir,
      type: 'TV Shows'
    )

    library = {
      'showExample' => {
        type: 'tv shows',
        name: 'Example Show',
        full_name: 'Example Show',
        show: show,
        files: [{ name: @file_path }]
      }
    }

    MediaLibrarian::Services::CalendarFeedService.stub(:enrich_entries, ->(entries, **) { entries }) do
      Library.stub(:process_folder, library) { @service.scan(request) }
    end

    calendar = @db.rows.find { |row| row[:table] == :calendar_entries }
    assert_equal 'show', calendar[:media_type]

    local_media = @db.rows.find { |row| row[:table] == :local_media }
    assert_equal 'show', local_media[:media_type]
  end

  def test_removes_watchlist_entry_for_detected_media
    show = Struct.new(:ids, :title).new({ 'imdb' => 'tt7654321' }, 'Example Show')
    request = MediaLibrarian::Services::FileSystemScanRequest.new(
      root_path: @tmp_dir,
      type: 'TV Shows'
    )

    library = {
      'showExample' => {
        type: 'tv shows',
        name: 'Example Show',
        full_name: 'Example Show',
        show: show,
        files: [{ name: @file_path }]
      }
    }

    MediaLibrarian::Services::CalendarFeedService.stub(:enrich_entries, ->(entries, **) { entries }) do
      Library.stub(:process_folder, library) { @service.scan(request) }
    end

    deletion = @db.deleted_rows.find { |row| row[:table] == :watchlist }
    assert_equal({ table: :watchlist, imdb_id: 'tt7654321', type: 'shows' }, deletion)
  end

  def test_re_enriches_calendar_entry_when_title_is_an_imdb_id
    @db.insert_row(:calendar_entries, {
      imdb_id: 'tt0453467',
      title: 'tt0453467',
      media_type: 'movie',
      source: 'local',
      external_id: 'tt0453467'
    })

    movie = Struct.new(:ids, :title).new({ 'imdb' => 'tt0453467' }, '')
    request = MediaLibrarian::Services::FileSystemScanRequest.new(root_path: @tmp_dir, type: 'movies')

    library = {
      'movie0453467' => {
        type: 'movies',
        movie: movie,
        files: [{ name: @file_path }]
      }
    }

    enriched = [{
      source: 'local',
      external_id: 'tt0453467',
      imdb_id: 'tt0453467',
      title: 'Déjà Vu',
      media_type: 'movie',
      ids: { 'imdb' => 'tt0453467' }
    }]

    MediaLibrarian::Services::CalendarFeedService.stub(:enrich_entries, ->(_entries, **) { enriched }) do
      Library.stub(:process_folder, library) { @service.scan(request) }
    end

    calendar_rows = @db.rows.select { |r| r[:table] == :calendar_entries }
    last_calendar = calendar_rows.last
    assert_equal 'Déjà Vu', last_calendar[:title]
  end
  def test_keeps_every_file_of_a_title
    second_path = File.join(@tmp_dir, 'Example (2021).part2.mkv')
    File.write(second_path, '')
    movie = Struct.new(:ids, :name, :year).new({ 'imdb' => 'tt1234567' }, 'Example (2021)', 2021)
    request = MediaLibrarian::Services::FileSystemScanRequest.new(root_path: @tmp_dir, type: 'movies')

    library = {
      'movieExample2021' => {
        type: 'movies',
        name: 'Example',
        movie: movie,
        files: [{ name: @file_path }, { name: second_path }]
      }
    }

    MediaLibrarian::Services::CalendarFeedService.stub(:enrich_entries, ->(entries, **) { entries }) do
      Library.stub(:process_folder, library) { @service.scan(request) }
    end

    local_media = @db.get_rows(:local_media)
    assert_equal [@file_path, second_path].sort, local_media.map { |row| row[:local_path] }.sort
    assert_equal ['tt1234567'], local_media.map { |row| row[:imdb_id] }.uniq
  end

  def test_recovers_imdb_id_from_entry_when_subject_carries_none
    movie = Struct.new(:ids, :name).new({ 'tmdb' => 4242 }, 'Example (2021)')
    request = MediaLibrarian::Services::FileSystemScanRequest.new(root_path: @tmp_dir, type: 'movies')

    library = {
      'movieExample2021' => {
        type: 'movies',
        external_id: 'tt5551212',
        movie: movie,
        files: [{ name: @file_path }]
      }
    }

    MediaLibrarian::Services::CalendarFeedService.stub(:enrich_entries, ->(entries, **) { entries }) do
      Library.stub(:process_folder, library) { @service.scan(request) }
    end

    local_media = @db.get_rows(:local_media).first
    assert_equal 'tt5551212', local_media[:imdb_id]
  end

  def test_ignores_non_imdb_fallback_identifiers
    movie = Struct.new(:ids, :name).new({ 'tmdb' => 4242 }, 'Example (2021)')
    request = MediaLibrarian::Services::FileSystemScanRequest.new(root_path: @tmp_dir, type: 'movies')

    library = {
      'movieExample2021' => {
        type: 'movies',
        external_id: 'example-slug',
        movie: movie,
        files: [{ name: @file_path }]
      }
    }

    MediaLibrarian::Services::CalendarFeedService.stub(:enrich_entries, ->(entries, **) { entries }) do
      Library.stub(:process_folder, library) { @service.scan(request) }
    end

    local_media = @db.get_rows(:local_media).first
    assert_nil local_media[:imdb_id]
  end

  def test_seeds_calendar_entry_with_the_resolved_name
    movie = Struct.new(:ids, :name, :release_date).new({ 'imdb' => 'tt9999999' }, 'Enola Holmes 3 (2026)', '2026-07-01')
    request = MediaLibrarian::Services::FileSystemScanRequest.new(root_path: @tmp_dir, type: 'movies')

    library = {
      'movieEnolaHolmes32026' => {
        type: 'movies',
        movie: movie,
        files: [{ name: @file_path }]
      }
    }

    MediaLibrarian::Services::CalendarFeedService.stub(:enrich_entries, ->(entries, **) { entries }) do
      Library.stub(:process_folder, library) { @service.scan(request) }
    end

    calendar = @db.get_rows(:calendar_entries).first
    assert_equal 'Enola Holmes 3', calendar[:title]
    assert_equal '2026-07-01', calendar[:release_date]
  end

  def test_seeds_show_calendar_entry_with_its_first_aired_date
    show = Struct.new(:ids, :name, :first_aired).new({ 'imdb' => 'tt7654321' }, 'Example Show (2019)', '2019-03-04')
    request = MediaLibrarian::Services::FileSystemScanRequest.new(root_path: @tmp_dir, type: 'shows')

    library = {
      'showExample' => {
        type: 'shows',
        show: show,
        files: [{ name: @file_path }]
      }
    }

    MediaLibrarian::Services::CalendarFeedService.stub(:enrich_entries, ->(entries, **) { entries }) do
      Library.stub(:process_folder, library) { @service.scan(request) }
    end

    calendar = @db.get_rows(:calendar_entries).first
    assert_equal 'Example Show', calendar[:title]
    assert_equal '2019-03-04', calendar[:release_date]
  end

  def test_updates_existing_row_when_imdb_id_becomes_resolvable
    @db.insert_row(:local_media, {
      media_type: 'movie',
      imdb_id: nil,
      local_path: @file_path,
      created_at: File.stat(@file_path).mtime
    })

    movie = Struct.new(:ids, :name).new({ 'imdb' => 'tt1234567' }, 'Example (2021)')
    request = MediaLibrarian::Services::FileSystemScanRequest.new(root_path: @tmp_dir, type: 'movies')

    library = {
      'movieExample2021' => {
        type: 'movies',
        movie: movie,
        files: [{ name: @file_path }]
      }
    }

    MediaLibrarian::Services::CalendarFeedService.stub(:enrich_entries, ->(entries, **) { entries }) do
      Library.stub(:process_folder, library) { @service.scan(request) }
    end

    local_media = @db.get_rows(:local_media)
    assert_equal 1, local_media.length
    assert_equal 'tt1234567', local_media.first[:imdb_id]
  end
  def test_cleanup_keeps_rows_whose_file_still_exists
    unmatched_path = File.join(@tmp_dir, 'Transient Failure (2020).mkv')
    File.write(unmatched_path, '')
    gone_path = File.join(@tmp_dir, 'Deleted Movie (2019).mkv')
    @db.insert_row(:local_media, { media_type: 'movie', imdb_id: 'ttkept', local_path: unmatched_path })
    @db.insert_row(:local_media, { media_type: 'movie', imdb_id: 'ttgone', local_path: gone_path })

    movie = Struct.new(:ids, :name).new({ 'imdb' => 'tt1234567' }, 'Example (2021)')
    request = MediaLibrarian::Services::FileSystemScanRequest.new(root_path: @tmp_dir, type: 'movies')

    # The library hash only carries the identified file: the transient-failure
    # one is on disk but absent, the deleted one is gone from disk.
    library = {
      'movieExample2021' => {
        type: 'movies',
        movie: movie,
        files: [{ name: @file_path }]
      }
    }

    MediaLibrarian::Services::CalendarFeedService.stub(:enrich_entries, ->(entries, **) { entries }) do
      Library.stub(:process_folder, library) { @service.scan(request) }
    end

    paths = @db.get_rows(:local_media).map { |row| row[:local_path] }
    assert_includes paths, unmatched_path, 'a file still on disk must keep its row even when unidentified this pass'
    refute_includes paths, gone_path, 'a file gone from disk must lose its row'
  end
end

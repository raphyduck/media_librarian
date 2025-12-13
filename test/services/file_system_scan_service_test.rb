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
    attr_reader :rows, :deleted_rows

    def initialize
      @rows = []
      @deleted_rows = []
    end

    def insert_row(table, values, or_replace = 0)
      @rows << values.merge(table: table.to_sym, replace: or_replace)
    end

    def get_rows(table, *_)
      @rows.select { |row| row[:table] == table.to_sym }
    end

    def delete_rows(table, conditions, *_)
      @deleted_rows << conditions.merge(table: table.to_sym)
      1
    end

    def table_exists?(table)
      %i[calendar_entries local_media watchlist].include?(table.to_sym)
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
    assert_equal 'movies', local_media[:media_type]
    assert_equal 'tt1234567', local_media[:imdb_id]
    assert_equal @file_path, local_media[:local_path]
    assert_equal 1, local_media[:replace]
  end

  def test_removes_watchlist_entry_for_detected_media
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

    deletion = @db.deleted_rows.find { |row| row[:table] == :watchlist }
    assert_equal({ table: :watchlist, imdb_id: 'tt1234567', type: 'movies' }, deletion)
  end
end

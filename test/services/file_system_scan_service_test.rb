# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

require_relative 'service_test_helper'
require_relative '../../lib/metadata'
require_relative '../../lib/media_librarian/services/file_system_scan_request'
require_relative '../../app/media_librarian/services/base_service'
require_relative '../../app/media_librarian/services/file_system_scan_service'

class FileSystemScanServiceTest < Minitest::Test
  class RecordingDb
    attr_reader :rows

    def initialize
      @rows = []
    end

    def insert_row(table, values, or_replace = 0)
      @rows << values.merge(table: table, replace: or_replace)
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
      folder_types: { @tmp_dir => 'movies' }
    )

    Metadata.stub(:identify_title, ['Example', movie]) do
      Metadata.stub(:parse_media_filename, ['Example (2021)', ['movieExample2021'], { movie: movie }]) do
        @service.scan(request)
      end
    end

    assert_equal 1, @db.rows.length
    row = @db.rows.first
    assert_equal 'local_media', row[:table]
    assert_equal 'movies', row[:media_type]
    assert_equal 'Example (2021)', row[:title]
    assert_equal 2021, row[:year]
    assert_equal 'tt1234567', row[:external_id]
    assert_equal @file_path, row[:local_path]
    assert_equal 1, row[:replace]
  end
end

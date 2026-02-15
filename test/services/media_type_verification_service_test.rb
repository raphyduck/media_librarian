# frozen_string_literal: true

require_relative 'service_test_helper'
require_relative '../../app/media_librarian/services/base_service'
require_relative '../../app/media_librarian/services/media_type_verification_service'

VALID_MEDIA_TYPES = { video: %w[movies shows] }.freeze unless defined?(VALID_MEDIA_TYPES)

# Ensure Utils has the methods used by MediaTypeVerificationService
class Utils
  class << self
    unless method_defined?(:canonical_media_type)
      def canonical_media_type(type)
        normalized = type.to_s.strip.downcase
        return 'movie' if normalized.start_with?('movie')
        return 'show' if normalized.start_with?('show') || normalized.start_with?('tv') || normalized.start_with?('series')

        normalized
      end
    end

    unless method_defined?(:regularise_media_type)
      def regularise_media_type(type)
        return type + 's' if VALID_MEDIA_TYPES.map { |_, v| v }.flatten.include?(type + 's')

        type
      rescue StandardError
        type
      end
    end
  end
end

class MediaTypeVerificationServiceTest < Minitest::Test
  class RecordingDb
    attr_reader :rows, :updated_rows

    def initialize(rows = [])
      @rows = rows
      @updated_rows = []
    end

    def get_rows(table, conditions = {}, _additionals = {})
      rows.select do |row|
        row[:_table] == table.to_sym &&
          conditions.all? { |k, v| row[k].to_s == v.to_s }
      end
    end

    def update_rows(table, values, conditions, _additionals = {})
      updated_rows << { table: table.to_sym, values: values, conditions: conditions }
      1
    end

    def table_exists?(table)
      %i[local_media calendar_entries watchlist].include?(table.to_sym)
    end
  end

  class FakeOmdbApi
    attr_reader :lookups

    def initialize(responses = {})
      @responses = responses
      @lookups = []
    end

    def title(imdb_id)
      @lookups << imdb_id
      @responses[imdb_id]
    end
  end

  def setup
    @speaker = TestSupport::Fakes::Speaker.new
  end

  def test_empty_database_returns_no_corrections
    db = RecordingDb.new
    app = Struct.new(:db, :speaker, :config).new(db, @speaker, {})
    service = MediaLibrarian::Services::MediaTypeVerificationService.new(app: app, speaker: @speaker)

    result = service.verify(fix: 0)

    assert_equal 0, result[:summary][:mismatched]
    assert_empty result[:corrections]
  end

  def test_consistent_entries_report_no_mismatch
    db = RecordingDb.new([
      { _table: :local_media, imdb_id: 'tt1234567', media_type: 'movie', local_path: '/movies/example.mkv' },
      { _table: :calendar_entries, imdb_id: 'tt1234567', media_type: 'movie', title: 'Example Movie' }
    ])
    app = Struct.new(:db, :speaker, :config).new(db, @speaker, {})
    service = MediaLibrarian::Services::MediaTypeVerificationService.new(app: app, speaker: @speaker)

    result = service.verify(fix: 0)

    assert_equal 0, result[:summary][:mismatched]
    assert_empty result[:corrections]
  end

  def test_detects_mismatch_between_local_media_and_calendar
    db = RecordingDb.new([
      { _table: :local_media, imdb_id: 'tt1234567', media_type: 'show', local_path: '/shows/Bugonia.mkv' },
      { _table: :calendar_entries, imdb_id: 'tt1234567', media_type: 'movie', title: 'Bugonia' }
    ])
    omdb = FakeOmdbApi.new('tt1234567' => { media_type: 'movie', title: 'Bugonia' })
    app = Struct.new(:db, :speaker, :config).new(db, @speaker, {})
    service = MediaLibrarian::Services::MediaTypeVerificationService.new(app: app, speaker: @speaker, omdb_api: omdb)

    result = service.verify(fix: 0)

    assert_equal 1, result[:summary][:mismatched]
    correction = result[:corrections].first
    assert_equal 'tt1234567', correction[:imdb_id]
    assert_equal 'show', correction[:wrong_type]
    assert_equal 'movie', correction[:correct_type]
    assert_includes correction[:tables], 'local_media'
  end

  def test_fix_mode_updates_local_media
    db = RecordingDb.new([
      { _table: :local_media, imdb_id: 'tt1234567', media_type: 'show', local_path: '/shows/Bugonia.mkv' },
      { _table: :calendar_entries, imdb_id: 'tt1234567', media_type: 'movie', title: 'Bugonia' }
    ])
    omdb = FakeOmdbApi.new('tt1234567' => { media_type: 'movie', title: 'Bugonia' })
    app = Struct.new(:db, :speaker, :config).new(db, @speaker, {})
    service = MediaLibrarian::Services::MediaTypeVerificationService.new(app: app, speaker: @speaker, omdb_api: omdb)

    result = service.verify(fix: 1, no_prompt: 1)

    assert_equal 1, result[:summary][:fixed]
    assert result[:corrections].first[:fixed]

    local_media_update = db.updated_rows.find { |u| u[:table] == :local_media }
    assert local_media_update, 'Expected local_media update'
    assert_equal 'movie', local_media_update[:values][:media_type]
    assert_equal 'tt1234567', local_media_update[:conditions][:imdb_id]
    assert_equal 'show', local_media_update[:conditions][:media_type]
  end

  def test_dry_run_does_not_update_database
    db = RecordingDb.new([
      { _table: :local_media, imdb_id: 'tt1234567', media_type: 'show', local_path: '/shows/Bugonia.mkv' },
      { _table: :calendar_entries, imdb_id: 'tt1234567', media_type: 'movie', title: 'Bugonia' }
    ])
    omdb = FakeOmdbApi.new('tt1234567' => { media_type: 'movie', title: 'Bugonia' })
    app = Struct.new(:db, :speaker, :config).new(db, @speaker, {})
    service = MediaLibrarian::Services::MediaTypeVerificationService.new(app: app, speaker: @speaker, omdb_api: omdb)

    result = service.verify(fix: 0)

    assert_equal 1, result[:summary][:mismatched]
    assert_equal 0, result[:summary][:fixed]
    assert_empty db.updated_rows
  end

  def test_omdb_verifies_consistent_but_wrong_entries
    db = RecordingDb.new([
      { _table: :local_media, imdb_id: 'tt9999999', media_type: 'show', local_path: '/shows/MovieX.mkv' },
      { _table: :calendar_entries, imdb_id: 'tt9999999', media_type: 'show', title: 'Movie X' }
    ])
    omdb = FakeOmdbApi.new('tt9999999' => { media_type: 'movie', title: 'Movie X' })
    app = Struct.new(:db, :speaker, :config).new(db, @speaker, {})
    service = MediaLibrarian::Services::MediaTypeVerificationService.new(app: app, speaker: @speaker, omdb_api: omdb)

    result = service.verify(fix: 1, no_prompt: 1)

    assert_equal 1, result[:summary][:mismatched]
    assert_equal 1, result[:summary][:fixed]

    correction = result[:corrections].first
    assert_equal 'show', correction[:wrong_type]
    assert_equal 'movie', correction[:correct_type]
    assert_includes correction[:tables], 'local_media'
    assert_includes correction[:tables], 'calendar_entries'
  end

  def test_fixes_both_local_media_and_calendar_entries
    db = RecordingDb.new([
      { _table: :local_media, imdb_id: 'tt9999999', media_type: 'show', local_path: '/shows/MovieX.mkv' },
      { _table: :calendar_entries, imdb_id: 'tt9999999', media_type: 'show', title: 'Movie X' }
    ])
    omdb = FakeOmdbApi.new('tt9999999' => { media_type: 'movie', title: 'Movie X' })
    app = Struct.new(:db, :speaker, :config).new(db, @speaker, {})
    service = MediaLibrarian::Services::MediaTypeVerificationService.new(app: app, speaker: @speaker, omdb_api: omdb)

    service.verify(fix: 1, no_prompt: 1)

    tables_updated = db.updated_rows.map { |u| u[:table] }
    assert_includes tables_updated, :local_media
    assert_includes tables_updated, :calendar_entries
  end

  def test_fixes_watchlist_entries_too
    db = RecordingDb.new([
      { _table: :local_media, imdb_id: 'tt1111111', media_type: 'show', local_path: '/shows/Film.mkv' },
      { _table: :calendar_entries, imdb_id: 'tt1111111', media_type: 'movie', title: 'Film' },
      { _table: :watchlist, imdb_id: 'tt1111111', type: 'shows' }
    ])
    omdb = FakeOmdbApi.new('tt1111111' => { media_type: 'movie', title: 'Film' })
    app = Struct.new(:db, :speaker, :config).new(db, @speaker, {})
    service = MediaLibrarian::Services::MediaTypeVerificationService.new(app: app, speaker: @speaker, omdb_api: omdb)

    service.verify(fix: 1, no_prompt: 1)

    watchlist_update = db.updated_rows.find { |u| u[:table] == :watchlist }
    assert watchlist_update, 'Expected watchlist update'
    assert_equal 'movies', watchlist_update[:values][:type]
  end

  def test_without_omdb_resolves_conflict_by_heuristic
    db = RecordingDb.new([
      { _table: :local_media, imdb_id: 'tt5555555', media_type: 'show', local_path: '/shows/Film.mkv' },
      { _table: :calendar_entries, imdb_id: 'tt5555555', media_type: 'movie', title: 'Film' }
    ])
    app = Struct.new(:db, :speaker, :config).new(db, @speaker, {})
    service = MediaLibrarian::Services::MediaTypeVerificationService.new(app: app, speaker: @speaker, omdb_api: nil)

    result = service.verify(fix: 1, no_prompt: 1)

    assert_equal 1, result[:summary][:mismatched]
    correction = result[:corrections].first
    assert_equal 'movie', correction[:correct_type]
    assert_equal 'show', correction[:wrong_type]
  end

  def test_no_omdb_consistent_entries_no_mismatch
    db = RecordingDb.new([
      { _table: :local_media, imdb_id: 'tt8888888', media_type: 'show', local_path: '/shows/Series.mkv' },
      { _table: :calendar_entries, imdb_id: 'tt8888888', media_type: 'show', title: 'Series' }
    ])
    app = Struct.new(:db, :speaker, :config).new(db, @speaker, {})
    service = MediaLibrarian::Services::MediaTypeVerificationService.new(app: app, speaker: @speaker, omdb_api: nil)

    result = service.verify(fix: 0)

    assert_equal 0, result[:summary][:mismatched]
  end

  def test_multiple_mismatches_all_detected
    db = RecordingDb.new([
      { _table: :local_media, imdb_id: 'tt0000001', media_type: 'show', local_path: '/shows/Movie1.mkv' },
      { _table: :calendar_entries, imdb_id: 'tt0000001', media_type: 'movie', title: 'Movie 1' },
      { _table: :local_media, imdb_id: 'tt0000002', media_type: 'show', local_path: '/shows/Movie2.mkv' },
      { _table: :calendar_entries, imdb_id: 'tt0000002', media_type: 'movie', title: 'Movie 2' },
      { _table: :local_media, imdb_id: 'tt0000003', media_type: 'movie', local_path: '/movies/Series1.mkv' },
      { _table: :calendar_entries, imdb_id: 'tt0000003', media_type: 'movie', title: 'Series 1' }
    ])
    omdb = FakeOmdbApi.new(
      'tt0000001' => { media_type: 'movie', title: 'Movie 1' },
      'tt0000002' => { media_type: 'movie', title: 'Movie 2' },
      'tt0000003' => { media_type: 'show', title: 'Series 1' }
    )
    app = Struct.new(:db, :speaker, :config).new(db, @speaker, {})
    service = MediaLibrarian::Services::MediaTypeVerificationService.new(app: app, speaker: @speaker, omdb_api: omdb)

    result = service.verify(fix: 1, no_prompt: 1)

    assert_equal 3, result[:summary][:mismatched]
    assert_equal 3, result[:summary][:fixed]

    imdb_ids = result[:corrections].map { |c| c[:imdb_id] }.sort
    assert_equal %w[tt0000001 tt0000002 tt0000003], imdb_ids
  end

  def test_omdb_failure_does_not_crash
    db = RecordingDb.new([
      { _table: :local_media, imdb_id: 'tt4444444', media_type: 'show', local_path: '/shows/Film.mkv' },
      { _table: :calendar_entries, imdb_id: 'tt4444444', media_type: 'movie', title: 'Film' }
    ])
    error_omdb = FakeOmdbApi.new
    def error_omdb.title(_)
      raise StandardError, 'API error'
    end
    app = Struct.new(:db, :speaker, :config).new(db, @speaker, {})
    service = MediaLibrarian::Services::MediaTypeVerificationService.new(app: app, speaker: @speaker, omdb_api: error_omdb)

    result = service.verify(fix: 1, no_prompt: 1)

    # Should still resolve via heuristic fallback
    assert_equal 1, result[:summary][:mismatched]
  end

  def test_entries_without_imdb_id_are_skipped
    db = RecordingDb.new([
      { _table: :local_media, imdb_id: '', media_type: 'show', local_path: '/shows/Unknown.mkv' },
      { _table: :local_media, imdb_id: nil, media_type: 'movie', local_path: '/movies/Unknown2.mkv' }
    ])
    app = Struct.new(:db, :speaker, :config).new(db, @speaker, {})
    service = MediaLibrarian::Services::MediaTypeVerificationService.new(app: app, speaker: @speaker)

    result = service.verify(fix: 0)

    assert_equal 0, result[:summary][:mismatched]
  end

  def test_speaker_logs_mismatch_details
    db = RecordingDb.new([
      { _table: :local_media, imdb_id: 'tt1234567', media_type: 'show', local_path: '/shows/Bugonia.mkv' },
      { _table: :calendar_entries, imdb_id: 'tt1234567', media_type: 'movie', title: 'Bugonia' }
    ])
    omdb = FakeOmdbApi.new('tt1234567' => { media_type: 'movie', title: 'Bugonia' })
    app = Struct.new(:db, :speaker, :config).new(db, @speaker, {})
    service = MediaLibrarian::Services::MediaTypeVerificationService.new(app: app, speaker: @speaker, omdb_api: omdb)

    service.verify(fix: 0)

    mismatch_messages = @speaker.messages.select { |m| m.include?('Mismatch') }
    assert_equal 1, mismatch_messages.size
    assert_includes mismatch_messages.first, 'Bugonia'
    assert_includes mismatch_messages.first, 'show'
    assert_includes mismatch_messages.first, 'movie'
  end
end

# frozen_string_literal: true

require 'ostruct'
require 'tmpdir'

require_relative 'service_test_helper'
require_relative '../../app/media_librarian/services'
require_relative '../../app/media_librarian/services/base_service'
require_relative '../../app/media_librarian/services/list_management_service'
require_relative '../../lib/media_librarian/application'
require_relative '../../app/library'
require_relative '../../lib/metadata'
require_relative '../../lib/watchlist_store'
require_relative '../../lib/storage/db'

class ListManagementServiceTest < Minitest::Test
  def setup
    @speaker = TestSupport::Fakes::Speaker.new
    @service = MediaLibrarian::Services::ListManagementService.new(
      app: nil,
      speaker: @speaker,
      file_system: Minitest::Mock.new
    )
  end

  def test_get_search_list_returns_empty_when_source_invalid
    request = MediaLibrarian::Services::SearchListRequest.new(
      source_type: 'filesystem',
      category: 'movies',
      source: {}
    )

    existing_files, search_list = @service.get_search_list(request)

    assert_equal({ 'movies' => {} }, existing_files)
    assert_equal({}, search_list)
    assert_includes @speaker.messages.first, 'get_search_list'
  end

  def test_get_search_list_uses_cached_results_when_source_valid
    request = MediaLibrarian::Services::SearchListRequest.new(
      source_type: 'filesystem',
      category: 'movies',
      source: {
        'existing_folder' => { 'movies' => '/media/movies' },
        'list_name' => 'watchlist'
      }
    )

    cache_name = "filesystemmovies/media/movieswatchlist"
    existing_files = { cache_name => ['/media/movies/file.mkv'] }
    search_results = { cache_name => { 'file.mkv' => { size: 123 } } }

    @service.stub(:build_search_list, [search_results, existing_files]) do
      files, list = @service.get_search_list(request)

      assert_equal(['/media/movies/file.mkv'], files[cache_name])
      assert_equal({ 'file.mkv' => { size: 123 } }, list)
    end
  end

  def test_watchlist_source_reads_store_and_flags_calendar
    Dir.mktmpdir('watchlist-test') do |dir|
      db_path = File.join(dir, 'librarian.db')
      db = Storage::Db.new(db_path)
      app = OpenStruct.new(db: db, speaker: @speaker)
      previous_app = MediaLibrarian.instance_variable_get(:@application)
      MediaLibrarian.instance_variable_set(:@application, app)

      WatchlistStore.upsert([
        {
          external_id: 'tmdb-42',
          type: 'movies',
          title: 'Sample',
          metadata: { year: 2024, ids: { 'tmdb' => '42' }, calendar_entries: [{ external_id: 'tmdb-42' }] }
        }
      ])

      request = MediaLibrarian::Services::SearchListRequest.new(
        source_type: 'watchlist',
        category: 'movies',
        source: { 'existing_folder' => { 'movies' => '/media/movies' } }
      )

      parsed_media = { 'tmdb-42' => { already_followed: 1 } }
      Library.stub(:parse_media, parsed_media) do
        existing = { 'tmdb-42' => { identifier: 'tmdb-42' } }
        Library.stub(:process_folder, existing) do
          files, search_list = @service.get_search_list(request)

          assert_equal existing, files['movies']
          assert_equal parsed_media['tmdb-42'], search_list['tmdb-42']
          assert_equal true, search_list[:calendar_entries].first[:downloaded]
          assert_equal 'tmdb-42', search_list[:calendar_entries].first[:external_id]
        end
      end
    ensure
      MediaLibrarian.instance_variable_set(:@application, previous_app)
    end
  end
end

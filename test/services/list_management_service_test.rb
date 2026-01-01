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
  class StubLocalMediaRepository
    attr_reader :calls

    def initialize(response)
      @response = response
      @calls = []
    end

    def library_index(type:, folder:)
      @calls << { type: type, folder: folder }
      @response
    end
  end

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
        'list_name' => 'watchlist'
      }
    )

    cache_name = 'filesystemmovies'
    existing_files = { cache_name => ['file.mkv'] }
    search_results = { cache_name => { 'file.mkv' => { size: 123 } } }
    repository = Class.new do
      def initialize(response)
        @response = response
      end

      def library_index(**_args)
        @response
      end
    end.new({ 'tt001' => { identifier: 'tt001' } })

    @service.stub(:media_repository, repository) do
      @service.stub(:build_search_list, [search_results, existing_files]) do
        files, list = @service.get_search_list(request)

        assert_equal(['file.mkv'], files[cache_name])
        assert_equal({ 'file.mkv' => { size: 123 } }, list)
      end
    end
  end

  def test_watchlist_source_reads_store_and_flags_calendar
    Dir.mktmpdir('watchlist-test') do |dir|
      db_path = File.join(dir, 'librarian.db')
      db = Storage::Db.new(db_path)
      app = OpenStruct.new(db: db, speaker: @speaker)
      previous_app = MediaLibrarian.instance_variable_get(:@application)
      MediaLibrarian.instance_variable_set(:@application, app)

      db.insert_row(
        'calendar_entries',
        source: 'tmdb',
        external_id: 'tmdb-42',
        title: 'Sample',
        media_type: 'movie',
        imdb_id: 'tt0042',
        ids: { imdb: 'tt0042', tmdb: '42' }
      )

      WatchlistStore.upsert([
        {
          imdb_id: 'tt0042',
          type: 'movies',
          title: 'Sample'
        }
      ])

      request = MediaLibrarian::Services::SearchListRequest.new(
        source_type: 'watchlist',
        category: 'movies',
        source: {}
      )

      parsed_media = { 'tt0042' => { already_followed: 1 } }
      Library.stub(:parse_media, parsed_media) do
        repo_data = { 'tt0042' => { identifier: 'tt0042' } }
        repo = StubLocalMediaRepository.new(repo_data)
        LocalMediaRepository.stub(:new, repo) do
          Library.stub(:process_folder, ->(**_) { flunk 'process_folder should not be called' }) do
            files, search_list = @service.get_search_list(request)

            assert_equal repo_data, files['movies']
            assert_equal parsed_media['tt0042'], search_list['tt0042']
            assert_equal true, search_list[:calendar_entries].first[:downloaded]
            assert_equal 'tt0042', search_list[:calendar_entries].first[:imdb_id]
            assert_equal [{ type: 'movies', folder: nil }], repo.calls.map { |call| { type: call[:type], folder: call[:folder] } }.uniq
          end
        end
      end
    ensure
      MediaLibrarian.instance_variable_set(:@application, previous_app)
    end
  end

  def test_filesystem_source_reads_existing_media_from_db_only
    request = MediaLibrarian::Services::SearchListRequest.new(
      source_type: 'filesystem',
      category: 'movies',
      source: {
        'list_name' => 'library'
      }
    )

    repo_data = { 'tt0001' => { identifier: 'tt0001', files: [{ name: '/media/movies/sample.mkv' }] } }
    repo = StubLocalMediaRepository.new(repo_data)

    LocalMediaRepository.stub(:new, repo) do
      Library.stub(:process_folder, ->(**_) { flunk 'process_folder should not be invoked' }) do
        files, search_list = @service.get_search_list(request)

        assert_equal repo_data, files['movies']
        assert_equal repo_data, search_list
        assert_equal [{ type: 'movies', folder: nil }], repo.calls.map { |call| { type: call[:type], folder: call[:folder] } }.uniq
      end
    end
  end
end

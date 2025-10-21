# frozen_string_literal: true

require_relative 'service_test_helper'
require_relative '../../app/media_librarian/services'
require_relative '../../app/media_librarian/services/base_service'
require_relative '../../app/media_librarian/services/list_management_service'

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
end

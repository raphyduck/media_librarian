# frozen_string_literal: true

require 'json'
require 'ostruct'

require_relative 'test_helper'
require_relative '../app/daemon'
require_relative '../lib/watchlist_store'
require_relative '../lib/storage/db'
require_relative '../lib/media_librarian/session_crypto'

class DaemonMcpEndpointTest < Minitest::Test
  FakeResponse = TestSupport::Fakes::FakeResponse

  def setup
    @environment = build_stubbed_environment
    attach_db(Storage::Db.new(File.join(@environment.root_path, 'librarian.db')))
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
    Daemon.instance_variable_set(:@mcp_server, nil)
    Daemon.instance_variable_set(:@calendar_repository, nil)
  end

  def teardown
    Daemon.instance_variable_set(:@api_token, nil)
    MediaLibrarian.application = nil
    @environment&.cleanup
  end

  def post_mcp(message)
    response = FakeResponse.new
    request = OpenStruct.new(request_method: 'POST', body: JSON.dump(message), query: {}, path: '/mcp')
    Daemon.send(:handle_mcp_request, request, response)
    response
  end

  def call_tool(name, arguments = {})
    response = post_mcp('jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/call',
                        'params' => { 'name' => name, 'arguments' => arguments })
    assert_equal 200, response.status
    JSON.parse(response.body)['result']
  end

  def test_initialize_over_http
    response = post_mcp('jsonrpc' => '2.0', 'id' => 1, 'method' => 'initialize',
                        'params' => { 'protocolVersion' => '2025-06-18' })

    assert_equal 200, response.status
    assert_equal 'application/json', response['Content-Type']
    assert_equal 'media_librarian', JSON.parse(response.body)['result']['serverInfo']['name']
  end

  def test_notification_is_accepted_without_body
    response = post_mcp('jsonrpc' => '2.0', 'method' => 'notifications/initialized')

    assert_equal 202, response.status
    assert_equal '', response.body
  end

  def test_get_is_not_allowed
    response = FakeResponse.new
    Daemon.send(:handle_mcp_request, OpenStruct.new(request_method: 'GET', query: {}, path: '/mcp'), response)

    assert_equal 405, response.status
  end

  def test_add_calendar_movie_to_watchlist_with_imdb_id_only
    @environment.application.db.insert_row('calendar_entries', {
      source: 'tmdb', external_id: '42', imdb_id: 'tt0042',
      title: 'Backrooms', media_type: 'movie', release_date: '2026-10-01'
    })

    result = call_tool('liste_interets_ajouter', 'elements' => [{ 'imdb_id' => 'tt0042' }])

    refute result['isError'], result.inspect
    entries = WatchlistStore.fetch
    assert_equal [%w[tt0042 movies]], entries.map { |row| [row[:imdb_id], row[:type]] }

    listed = call_tool('liste_interets')
    assert_equal [%w[tt0042 Backrooms]], listed['structuredContent']['entries'].map { |entry| [entry['imdb_id'], entry['title']] }
  end

  def test_unknown_imdb_id_without_title_is_reported
    result = call_tool('liste_interets_ajouter', 'elements' => [{ 'imdb_id' => 'tt9999' }])

    assert result['isError']
    assert_includes result['structuredContent']['error'], 'missing_title'
    assert_empty WatchlistStore.fetch
  end

  def test_internal_call_resolves_prefixed_routes
    status, body = Daemon.send(:internal_api_call, 'GET', '/jobs/does-not-exist')

    assert_equal 404, status
    assert_equal 'not_found', body['error']
    assert_equal 404, Daemon.send(:internal_api_call, 'GET', '/nowhere').first
    assert_equal 404, Daemon.send(:internal_api_call, 'POST', '/mcp').first
  end

  def test_bearer_token_is_accepted
    Daemon.instance_variable_set(:@api_token, 'secret-token')

    assert Daemon.send(:api_token_authorized?, { 'Authorization' => 'Bearer secret-token' })
    refute Daemon.send(:api_token_authorized?, { 'Authorization' => 'Bearer wrong' })
    refute Daemon.send(:api_token_authorized?, { 'Authorization' => 'Basic secret-token' })
    assert Daemon.send(:api_token_authorized?, { 'X-Control-Token' => 'secret-token' })
  end
end

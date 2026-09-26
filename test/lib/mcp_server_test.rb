# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../../lib/media_librarian/version'
require_relative '../../lib/media_librarian/mcp_server'

class McpServerTest < Minitest::Test
  def setup
    @calls = []
    @responses = {}
    api = lambda do |method, path, query: {}, body: nil|
      @calls << { method: method, path: path, query: query, body: body }
      @responses.fetch([method, path], [200, { 'ok' => true }])
    end
    @server = MediaLibrarian::McpServer.new(api: api, version: '9.9')
  end

  def rpc(method, params = nil, id: 1)
    message = { 'jsonrpc' => '2.0', 'id' => id, 'method' => method }
    message['params'] = params if params
    @server.handle(message)
  end

  def call_tool(name, arguments = {})
    rpc('tools/call', { 'name' => name, 'arguments' => arguments })['result']
  end

  def test_initialize_echoes_supported_protocol_version
    result = rpc('initialize', { 'protocolVersion' => '2025-06-18', 'capabilities' => {} })['result']

    assert_equal '2025-06-18', result['protocolVersion']
    assert_equal({ 'listChanged' => false }, result['capabilities']['tools'])
    assert_equal '9.9', result['serverInfo']['version']
  end

  def test_initialize_falls_back_to_latest_version_for_unknown_request
    result = rpc('initialize', { 'protocolVersion' => '1999-01-01' })['result']

    assert_equal MediaLibrarian::McpServer::PROTOCOL_VERSIONS.first, result['protocolVersion']
  end

  def test_notifications_get_no_response
    assert_nil @server.handle({ 'jsonrpc' => '2.0', 'method' => 'notifications/initialized' })
  end

  def test_batch_answers_only_requests
    responses = @server.handle([
      { 'jsonrpc' => '2.0', 'method' => 'notifications/initialized' },
      { 'jsonrpc' => '2.0', 'id' => 7, 'method' => 'ping' }
    ])

    assert_equal [{ 'jsonrpc' => '2.0', 'id' => 7, 'result' => {} }], responses
  end

  def test_parse_error_and_unknown_method
    assert_equal(-32_700, @server.handle_json('{nope')['error']['code'])
    assert_equal(-32_601, rpc('nope/nope')['error']['code'])
    assert_equal(-32_600, @server.handle({ 'id' => 1 })['error']['code'])
  end

  def test_tools_list_exposes_schemas_and_annotations
    tools = rpc('tools/list')['result']['tools']
    names = tools.map { |tool| tool['name'] }

    %w[etat journaux lancer_commande tache redemarrer calendrier liste_interets_ajouter appeler_api].each do |name|
      assert_includes names, name
    end
    tools.each do |tool|
      assert_equal 'object', tool['inputSchema']['type'], tool['name']
      refute_nil tool['annotations']['readOnlyHint'], tool['name']
    end
    JSON.dump(tools)
  end

  def test_unknown_tool_is_a_protocol_error
    assert_equal(-32_602, rpc('tools/call', { 'name' => 'nope' })['error']['code'])
  end

  def test_status_tool_returns_structured_content
    @responses[%w[GET /status]] = [200, { 'jobs' => [], 'uptime_seconds' => 12 }]

    result = call_tool('etat')

    refute result['isError']
    assert_equal 12, result['structuredContent']['uptime_seconds']
    assert_equal 12, JSON.parse(result['content'].first['text'])['uptime_seconds']
  end

  def test_route_errors_become_tool_errors
    @responses[%w[POST /restart]] = [409, { 'error' => 'restart_in_progress' }]

    result = call_tool('redemarrer')

    assert result['isError']
    assert_includes result['structuredContent']['error'], 'restart_in_progress'
  end

  def test_logs_tool_filters_and_tails
    log = (1..10).map { |i| i.even? ? "ERROR line #{i}" : "info line #{i}" }.join("\n")
    @responses[%w[GET /logs]] = [200, { 'logs' => { 'medialibrarian.log' => log, 'medialibrarian_errors.log' => 'x' } }]

    result = call_tool('journaux', 'fichier' => 'general', 'lignes' => 2, 'filtre' => 'error')

    assert_equal({ 'medialibrarian.log' => "ERROR line 8\nERROR line 10" }, result['structuredContent']['logs'])
  end

  def test_launch_command_builds_cli_arguments
    @responses[%w[POST /jobs]] = [200, { 'job' => { 'id' => 'abc' }, 'accepted' => true }]

    result = call_tool('lancer_commande', 'commande' => 'library process_folder',
                                          'arguments' => { 'type' => 'shows', 'folder' => '/m', 'apply' => true })

    refute result['isError']
    body = @calls.last[:body]
    assert_equal %w[library process_folder --type=shows --folder=/m --apply=1], body['command']
    assert_equal true, body['capture_output']
  end

  def test_launch_command_reports_rejection
    @responses[%w[POST /jobs]] = [200, { 'job' => nil, 'accepted' => false }]

    assert call_tool('lancer_commande', 'commande' => %w[torrent search])['isError']
  end

  def test_job_tool_trims_output
    @responses[%w[GET /jobs/abc]] = [200, { 'id' => 'abc', 'output' => (1..50).map(&:to_s) }]

    result = call_tool('tache', 'id' => 'abc', 'lignes_sortie' => 3)

    assert_equal "48\n49\n50", result['structuredContent']['output']
  end

  def test_stop_requires_confirmation
    result = call_tool('arreter', 'confirmer' => false)

    assert result['isError']
    assert_empty @calls

    refute call_tool('arreter', 'confirmer' => true)['isError']
    assert_equal({ method: 'POST', path: '/stop', query: {}, body: nil }, @calls.last)
  end

  def test_calendar_tool_maps_filters_to_query
    call_tool('calendrier', 'type' => 'movie', 'interet' => false, 'genres' => %w[Drama Comedy], 'debut' => '2026-10-01')

    query = @calls.last[:query]
    assert_equal 'movie', query['type']
    assert_equal 'false', query['interest']
    assert_equal 'Drama,Comedy', query['genres']
    assert_equal '2026-10-01', query['start_date']
    refute query.key?('title')
  end

  def test_watchlist_add_posts_each_element_and_reports_partial_failures
    @responses[%w[POST /watchlist]] = [200, { 'status' => 'ok' }]

    result = call_tool('liste_interets_ajouter', 'elements' => [{ 'imdb_id' => 'tt1' }, { 'imdb_id' => 'tt2', 'type' => 'shows' }, {}])

    refute result['isError']
    assert_equal 2, result['structuredContent']['added']
    assert_equal [{ 'imdb_id' => 'tt1' }, { 'imdb_id' => 'tt2', 'type' => 'shows' }], @calls.map { |call| call[:body] }
  end

  def test_generic_api_guards
    assert call_tool('appeler_api', 'methode' => 'POST', 'chemin' => '/mcp')['isError']
    assert call_tool('appeler_api', 'methode' => 'PUT', 'chemin' => '/config', 'corps' => { 'content' => 'a: 1' })['isError']
    assert call_tool('appeler_api', 'methode' => 'GET', 'chemin' => '/../etc')['isError']
    assert_empty @calls

    refute call_tool('appeler_api', 'methode' => 'get', 'chemin' => 'music/search', 'parametres' => { 'query' => 'x' })['isError']
    assert_equal({ method: 'GET', path: '/music/search', query: { 'query' => 'x' }, body: nil }, @calls.last)
  end
end

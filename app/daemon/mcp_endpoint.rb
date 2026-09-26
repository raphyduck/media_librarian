# frozen_string_literal: true

# Model Context Protocol endpoint (/mcp, Streamable HTTP transport, stateless
# JSON responses) for the daemon control server. Tool calls are served by
# MediaLibrarian::McpServer, which reaches the control routes through
# internal_api_call: the request never leaves the process and runs the very
# handler the REST route runs, after /mcp itself passed require_authorization.
# Zeitwerk is told to ignore this file (see Application#setup_loader) because
# it reopens Daemon rather than defining a Daemon::McpEndpoint constant.

require_relative '../../lib/media_librarian/mcp_server'

class Daemon
  MCP_EXCLUDED_ROUTES = %w[/mcp /ws].freeze

  class << self
    def handle_mcp_request(req, res)
      case req.request_method
      when 'POST'
        response = mcp_server.handle_json(req.body)
        if response.nil?
          res.status = 202
          res.body = ''
        else
          json_response(res, body: response)
        end
      when 'GET', 'DELETE'
        # Stateless server: no server-initiated SSE stream, no session to end.
        method_not_allowed(res, 'POST')
      else
        method_not_allowed(res, 'POST')
      end
    end

    def mcp_server
      @mcp_server ||= MediaLibrarian::McpServer.new(api: method(:internal_api_call))
    end

    # Runs a control route in-process and returns [status, parsed_body].
    def internal_api_call(method, path, query: {}, body: nil)
      handler = internal_route_handler(path)
      return [404, { 'error' => 'not_found' }] unless handler

      req = SocketRequest.new(method: method, path: path, headers: {}, body: body.nil? ? nil : JSON.dump(body),
                              query: query)
      res = SocketResponse.new
      handler.call(req, res)
      parsed = res.body.to_s.empty? ? nil : JSON.parse(res.body)
      [res.status, parsed]
    rescue JSON::ParserError
      [500, { 'error' => 'invalid_response' }]
    end

    # WEBrick mounts match by path prefix ('/jobs' serves '/jobs/<id>'); mirror
    # that with a longest-prefix lookup over the authenticated routes.
    def internal_route_handler(path)
      candidates = authenticated_routes.reject { |route, _| MCP_EXCLUDED_ROUTES.include?(route) }
      match = candidates.keys
                        .select { |route| path == route || path.start_with?("#{route}/") }
                        .max_by(&:length)
      match && candidates[match]
    end
  end
end

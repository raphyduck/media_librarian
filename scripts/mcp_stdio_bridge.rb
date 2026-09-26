#!/usr/bin/env ruby
# frozen_string_literal: true

# stdio <-> HTTP bridge for the daemon's MCP endpoint, for MCP hosts that spawn
# a stdio server (mcp-oauth-proxy, Claude Desktop, ...). Standard library only,
# so it runs from any Ruby image without the application's bundle.
#
#   MEDIA_LIBRARIAN_URL        base URL of the control server (default http://127.0.0.1:8888)
#   MEDIA_LIBRARIAN_API_TOKEN  api_token from api.yml, sent as a Bearer token
#   MEDIA_LIBRARIAN_TIMEOUT    per-request timeout in seconds (default 120)
#   MEDIA_LIBRARIAN_INSECURE   1 to skip TLS verification (self-signed certificate)

require 'json'
require 'net/http'
require 'openssl'
require 'uri'

$stdout.sync = true

endpoint = URI.join(ENV.fetch('MEDIA_LIBRARIAN_URL', 'http://127.0.0.1:8888').sub(%r{/*\z}, '/'), 'mcp')
token = ENV['MEDIA_LIBRARIAN_API_TOKEN'].to_s
timeout = Integer(ENV.fetch('MEDIA_LIBRARIAN_TIMEOUT', '120'))

http = Net::HTTP.new(endpoint.host, endpoint.port)
http.use_ssl = endpoint.scheme == 'https'
http.verify_mode = OpenSSL::SSL::VERIFY_NONE if http.use_ssl? && ENV['MEDIA_LIBRARIAN_INSECURE'] == '1'
http.open_timeout = 10
http.read_timeout = timeout
http.keep_alive_timeout = 30

request_ids = lambda do |payload|
  Array(payload.is_a?(Array) ? payload : [payload]).filter_map do |message|
    message['id'] if message.is_a?(Hash) && message.key?('id') && message.key?('method')
  end
end

$stdin.each_line do |line|
  line = line.strip
  next if line.empty?

  ids = begin
    request_ids.call(JSON.parse(line))
  rescue JSON::ParserError
    [nil]
  end

  begin
    request = Net::HTTP::Post.new(endpoint)
    request['Content-Type'] = 'application/json'
    request['Accept'] = 'application/json, text/event-stream'
    request['Authorization'] = "Bearer #{token}" unless token.empty?
    request.body = line
    http.start unless http.started?
    response = http.request(request)

    if response.code.to_i == 202 || response.body.to_s.strip.empty?
      next if ids.empty?

      raise "HTTP #{response.code} without body"
    end
    raise "HTTP #{response.code}: #{response.body.to_s[0, 500]}" unless response.code.to_i.between?(200, 299)

    $stdout.puts(response.body.strip)
  rescue StandardError => e
    warn "mcp_stdio_bridge: #{e.class}: #{e.message}"
    ids.each do |id|
      $stdout.puts(JSON.dump('jsonrpc' => '2.0', 'id' => id,
                             'error' => { 'code' => -32_603, 'message' => "media_librarian unreachable: #{e.message}" }))
    end
    http.finish if http.started? rescue nil
  end
end

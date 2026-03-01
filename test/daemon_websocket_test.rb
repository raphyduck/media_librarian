# frozen_string_literal: true

require 'socket'
require 'thread'
require 'timeout'
require 'json'
require 'net/http'
require 'fileutils'
require 'bcrypt'
require 'openssl'
require 'base64'
require 'test_helper'
require_relative '../lib/simple_speaker'
require_relative '../app/daemon'
require_relative '../app/client'

class DaemonWebsocketTest < Minitest::Test
  def setup
    reset_librarian_state!
  end

  def teardown
    Daemon.stop if Daemon.running?
    @daemon_thread&.join
    @environment&.cleanup
    MediaLibrarian.application = nil
  end

  def test_ws_endpoint_rejects_plain_http_get
    boot_daemon_environment

    response = control_get('/ws')
    assert_equal 426, response[:status_code]
    assert_equal 'websocket_upgrade_required', response.dig(:body, 'error')
  end

  def test_ws_endpoint_rejects_unauthenticated_connection
    boot_daemon_environment(authenticate: false)

    socket = open_tcp_socket
    send_ws_upgrade(socket, '/ws', cookie: nil, token: nil)
    response_line = socket.gets
    assert_match(/403/, response_line, 'Expected 403 for unauthenticated WS connection')
  ensure
    socket&.close rescue nil
  end

  def test_ws_endpoint_upgrades_connection_with_session_cookie
    boot_daemon_environment

    socket = open_tcp_socket
    send_ws_upgrade(socket, '/ws', cookie: @session_cookie, token: nil)
    response_headers = read_http_response_headers(socket)

    assert_match(/101/, response_headers.first, 'Expected 101 Switching Protocols')
    assert response_headers.any? { |h| h.downcase.include?('upgrade: websocket') }
    assert response_headers.any? { |h| h.downcase.include?('sec-websocket-accept:') }
  ensure
    ws_send_close(socket) rescue nil
    socket&.close rescue nil
  end

  def test_ws_endpoint_upgrades_connection_with_api_token
    boot_daemon_environment(authenticate: false)

    socket = open_tcp_socket
    send_ws_upgrade(socket, '/ws', cookie: nil, token: @api_token)
    response_headers = read_http_response_headers(socket)

    assert_match(/101/, response_headers.first, 'Expected 101 Switching Protocols with API token')
  ensure
    ws_send_close(socket) rescue nil
    socket&.close rescue nil
  end

  def test_ws_receives_status_broadcast_on_job_completion
    boot_daemon_environment

    socket = open_tcp_socket
    send_ws_upgrade(socket, '/ws', cookie: @session_cookie, token: nil)
    read_http_response_headers(socket)

    Client.new.enqueue(['Library', 'noop'], wait: true)

    message = ws_read_json_message(socket, timeout: 5)
    refute_nil message, 'Expected a WebSocket message after job completion'
    assert_equal 'status', message['type'], 'Expected status message type'
    data = message['data']
    assert_kind_of Hash, data
    assert data.key?('jobs'), 'status data should include jobs'
  ensure
    ws_send_close(socket) rescue nil
    socket&.close rescue nil
  end

  def test_ws_receives_job_update_broadcast_on_job_completion
    boot_daemon_environment

    socket = open_tcp_socket
    send_ws_upgrade(socket, '/ws', cookie: @session_cookie, token: nil)
    read_http_response_headers(socket)

    Client.new.enqueue(['Library', 'noop'], wait: true)

    job_update = nil
    Timeout.timeout(5) do
      loop do
        message = ws_read_json_message(socket, timeout: 2)
        break unless message

        if message['type'] == 'job_update'
          job_update = message['data']
          break
        end
      end
    end

    refute_nil job_update, 'Expected a job_update message after job completion'
    assert job_update.key?('id')
    assert job_update.key?('status')
  ensure
    ws_send_close(socket) rescue nil
    socket&.close rescue nil
  end

  def test_ws_multiple_clients_all_receive_broadcast
    boot_daemon_environment

    socket1 = open_tcp_socket
    socket2 = open_tcp_socket

    send_ws_upgrade(socket1, '/ws', cookie: @session_cookie, token: nil)
    read_http_response_headers(socket1)

    send_ws_upgrade(socket2, '/ws', cookie: @session_cookie, token: nil)
    read_http_response_headers(socket2)

    Client.new.enqueue(['Library', 'noop'], wait: true)

    msg1 = ws_read_json_message(socket1, timeout: 5)
    msg2 = ws_read_json_message(socket2, timeout: 5)

    refute_nil msg1, 'First client should receive broadcast'
    refute_nil msg2, 'Second client should receive broadcast'
  ensure
    ws_send_close(socket1) rescue nil
    socket1&.close rescue nil
    ws_send_close(socket2) rescue nil
    socket2&.close rescue nil
  end

  private

  def boot_daemon_environment(authenticate: true, **opts)
    credentials = { username: 'operator', password: 'secret-pass' }
    @auth_credentials = credentials
    @session_cookie = nil
    @api_token = nil
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
    Client.configure(app: @environment.application)

    override_port(credentials: credentials, **opts.slice(:api_overrides, :control_token).merge({}))

    Librarian.new(container: @environment.container, args: [])

    @daemon_thread = Thread.new do
      Daemon.start(scheduler: nil, daemonize: false)
    end

    wait_for_http_ready
    authenticate_session if authenticate
  end

  def override_port(credentials:, control_token: nil, api_overrides: {})
    port = free_port
    @daemon_port = port
    token = control_token || 'ws-test-token'
    hashed_password = BCrypt::Password.create(credentials.fetch(:password)).to_s
    options = {
      'bind_address' => '127.0.0.1',
      'listen_port' => port,
      'auth' => {
        'username' => credentials.fetch(:username),
        'password_hash' => hashed_password
      },
      'api_token' => token,
      'control_token' => token
    }
    options.merge!(api_overrides) if api_overrides
    @api_token = token

    config_path = @environment.application.api_config_file
    File.write(config_path, options.transform_keys(&:to_s).to_yaml)
    @environment.container.reload_api_option!
  end

  def free_port
    TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }
  end

  def daemon_host
    @environment.application.api_option['bind_address'] || '127.0.0.1'
  end

  def daemon_port
    @environment.application.api_option['listen_port']
  end

  def wait_for_http_ready
    Timeout.timeout(10) do
      loop do
        response = Client.new.status
        break if response['status_code'] == 200

        sleep 0.05
      rescue Errno::ECONNREFUSED
        sleep 0.05
      end
    end
  end

  def authenticate_session
    uri = URI::HTTP.build(host: daemon_host, port: daemon_port, path: '/session')
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request.body = JSON.dump(
      'username' => @auth_credentials.fetch(:username),
      'password' => @auth_credentials.fetch(:password)
    )
    response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
    cookies = response.get_fields('set-cookie') || []
    session_cookie = cookies.find { |c| c.start_with?("#{Daemon::SESSION_COOKIE_NAME}=") }
    @session_cookie = session_cookie&.split(';')&.first
    assert_equal '201', response.code, "Session authentication failed"
  end

  def control_get(path)
    uri = URI::HTTP.build(host: daemon_host, port: daemon_port, path: path)
    request = Net::HTTP::Get.new(uri)
    request['Cookie'] = @session_cookie if @session_cookie
    request['X-Control-Token'] = @api_token if @api_token
    response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
    raw = response.body.to_s
    parsed = raw.empty? ? nil : JSON.parse(raw) rescue raw
    { status_code: response.code.to_i, body: parsed }
  end

  def open_tcp_socket
    TCPSocket.new(daemon_host, daemon_port)
  end

  def ws_key
    Base64.strict_encode64(SecureRandom.random_bytes(16))
  end

  def send_ws_upgrade(socket, path, cookie: nil, token: nil)
    key = ws_key
    headers = [
      "GET #{path} HTTP/1.1",
      "Host: #{daemon_host}:#{daemon_port}",
      'Upgrade: websocket',
      'Connection: Upgrade',
      "Sec-WebSocket-Key: #{key}",
      'Sec-WebSocket-Version: 13'
    ]
    headers << "Cookie: #{cookie}" if cookie
    headers << "X-Control-Token: #{token}" if token
    socket.write(headers.join("\r\n") + "\r\n\r\n")
    key
  end

  def read_http_response_headers(socket)
    lines = []
    Timeout.timeout(5) do
      loop do
        line = socket.gets
        break if line.nil? || line.chomp.empty?

        lines << line.chomp
      end
    end
    lines
  end

  def ws_encode_close_frame
    "\x88\x82\x00\x00\x00\x00\x03\xe8".b
  end

  def ws_send_close(socket)
    return unless socket && !socket.closed?

    socket.write(ws_encode_close_frame)
  rescue IOError, Errno::ECONNRESET, Errno::EPIPE
    nil
  end

  def ws_read_frame(socket, timeout: 3)
    Timeout.timeout(timeout) do
      header = socket.read(2)
      return nil if header.nil? || header.bytesize < 2

      b1 = header.getbyte(1)
      len = b1 & 0x7F

      if len == 126
        extra = socket.read(2)
        return nil unless extra&.bytesize == 2

        len = extra.unpack1('n')
      elsif len == 127
        extra = socket.read(8)
        return nil unless extra&.bytesize == 8

        len = extra.unpack1('Q>')
      end

      payload = len.positive? ? socket.read(len) : ''.b
      return nil if payload.nil? || payload.bytesize < len

      payload.force_encoding('UTF-8')
    end
  rescue Timeout::Error, IOError, EOFError, Errno::ECONNRESET
    nil
  end

  def ws_read_json_message(socket, timeout: 3)
    payload = ws_read_frame(socket, timeout: timeout)
    return nil unless payload

    JSON.parse(payload)
  rescue JSON::ParserError
    nil
  end
end

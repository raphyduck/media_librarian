# frozen_string_literal: true

require 'test_helper'
require_relative '../app/daemon'

class DaemonWebsocketTest < Minitest::Test
  FakeSocket = Struct.new(:buffer, :closed_flag) do
    def initialize
      super(+'', false)
    end

    def write(data)
      self.buffer << data
    end

    def close
      self.closed_flag = true
    end

    def closed?
      closed_flag
    end
  end

  def setup
    reset_librarian_state!
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
  end

  def teardown
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def test_websocket_handshake_response_contains_expected_accept
    key = 'dGhlIHNhbXBsZSBub25jZQ=='

    response = Daemon.send(:websocket_handshake_response, key)

    assert_includes response, 'HTTP/1.1 101 Switching Protocols'
    assert_includes response, 'Upgrade: websocket'
    assert_includes response, 'Connection: Upgrade'
    assert_includes response, 'Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo='
  end

  def test_websocket_text_frame_for_short_payload
    frame = Daemon.send(:websocket_text_frame, 'ok')

    assert_equal 0x81, frame.getbyte(0)
    assert_equal 2, frame.getbyte(1)
    assert_equal 'ok', frame.byteslice(2..)
  end

  def test_websocket_socket_accepts_direct_socket_object
    req_socket = FakeSocket.new
    response = Object.new

    socket = Daemon.send(:websocket_socket, req_socket, response)

    assert_same req_socket, socket
  end

  def test_websocket_socket_finds_nested_wrapped_socket
    wrapped_socket = Object.new
    inner_socket = FakeSocket.new
    wrapped_socket.instance_variable_set(:@socket, inner_socket)
    request = Object.new
    response = Object.new
    response.instance_variable_set(:@config, { ssl: wrapped_socket })

    socket = Daemon.send(:websocket_socket, request, response)

    assert_same inner_socket, socket
  end

  def test_websocket_socket_logs_request_and_response_shape_when_missing
    request = Struct.new(:query).new({})
    request.instance_variable_set(:@peeraddr, ['127.0.0.1'])
    response = Object.new

    _stdout, stderr = capture_io do
      assert_nil Daemon.send(:websocket_socket, request, response)
    end

    assert_includes stderr, 'WebSocket socket unavailable'
    assert_includes stderr, request.class.to_s
    assert_includes stderr, response.class.to_s
  end

  def test_websocket_text_frame_for_126_plus_payload
    payload = 'a' * 130

    frame = Daemon.send(:websocket_text_frame, payload)

    assert_equal 0x81, frame.getbyte(0)
    assert_equal 126, frame.getbyte(1)
    assert_equal 130, (frame.getbyte(2) << 8) | frame.getbyte(3)
    assert_equal payload, frame.byteslice(4..)
  end
end

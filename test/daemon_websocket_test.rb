# frozen_string_literal: true

require 'test_helper'
require_relative '../app/daemon'

class DaemonWebsocketTest < Minitest::Test
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

  def test_websocket_socket_prefers_request_socket
    req_socket = StringIO.new
    res_socket = StringIO.new
    request = Struct.new(:query).new({})
    response = Object.new
    request.instance_variable_set(:@socket, req_socket)
    response.instance_variable_set(:@socket, res_socket)

    socket = Daemon.send(:websocket_socket, request, response)

    assert_same req_socket, socket
  end

  def test_websocket_socket_falls_back_to_response_socket
    res_socket = StringIO.new
    request = Struct.new(:query).new({})
    response = Object.new
    response.instance_variable_set(:@socket, res_socket)

    socket = Daemon.send(:websocket_socket, request, response)

    assert_same res_socket, socket
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

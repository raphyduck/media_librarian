# frozen_string_literal: true

require 'json'
require 'socket'
require 'test_helper'
require_relative '../app/daemon'

class DaemonAuthenticationRequirementsTest < Minitest::Test
  def setup
    reset_librarian_state!
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
  end

  def teardown
    Daemon.stop if Daemon.running?
    @environment&.cleanup
    MediaLibrarian.application = nil
  end

  def test_require_authorization_rejects_when_auth_missing
    Daemon.instance_variable_set(:@api_token, nil)
    Daemon.instance_variable_set(:@auth_config, {})

    response = FakeResponse.new

    refute Daemon.send(:require_authorization, FakeRequest.new, response)
    assert_equal 503, response.status

    payload = JSON.parse(response.body)
    assert_equal 'auth_not_configured', payload['error']
  end

  def test_control_server_refuses_non_local_binding_without_auth
    application = @environment.application
    port = TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }
    application.api_option = {
      'bind_address' => '0.0.0.0',
      'listen_port' => port,
      'auth' => nil,
      'api_token' => nil,
      'control_token' => nil
    }
    @environment.container.reload_api_option!

    error = assert_raises(ArgumentError) { Daemon.send(:start_control_server) }
    assert_includes error.message, 'Authentication required'
    assert_nil Daemon.instance_variable_get(:@control_server)
  ensure
    Daemon.instance_variable_set(:@control_server, nil)
    Daemon.instance_variable_set(:@control_thread, nil)
  end

  class FakeRequest; end

  FakeResponse = TestSupport::Fakes::FakeResponse
end

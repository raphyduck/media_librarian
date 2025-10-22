# frozen_string_literal: true

require 'minitest/mock'
require 'test_helper'
require_relative '../app/daemon'
require_relative '../app/client'

class DaemonCliStopTest < Minitest::Test
  def setup
    super
    reset_librarian_state!
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
    Client.configure(app: @environment.application)
  end

  def teardown
    MediaLibrarian.application = nil
    remove_app_reference(Daemon)
    remove_app_reference(Client)
    @environment&.cleanup
    reset_librarian_state!
    super
  end

  def test_stop_invokes_remote_client_when_not_running
    response = { 'status_code' => 200, 'body' => { 'status' => 'stopping' } }
    fake_client = Minitest::Mock.new
    fake_client.expect(:stop, response)

    result = Client.stub(:new, ->(*_) { fake_client }) do
      Daemon.stop
    end

    assert result
    assert_includes @environment.application.speaker.messages, 'Stop command sent to daemon'
  ensure
    fake_client.verify if defined?(fake_client)
  end

  def test_stop_reports_missing_daemon_when_remote_unavailable
    response = { 'status_code' => 503, 'error' => 'connection refused' }
    fake_client = Minitest::Mock.new
    fake_client.expect(:stop, response)

    result = Client.stub(:new, ->(*_) { fake_client }) do
      Daemon.stop
    end

    refute result
    assert_includes @environment.application.speaker.messages, 'No daemon running'
  ensure
    fake_client.verify if defined?(fake_client)
  end

  private

  def remove_app_reference(klass)
    singleton = klass.singleton_class
    if singleton.instance_variable_defined?(:@app)
      singleton.remove_instance_variable(:@app)
    end
  end
end

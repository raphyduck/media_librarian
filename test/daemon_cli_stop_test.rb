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

  def test_stop_runs_shutdown_in_background_when_called_from_job_thread
    Librarian.new(container: @environment.container, args: [])
    Daemon.instance_variable_set(:@running, Concurrent::AtomicBoolean.new(true))

    shutdown_threads = Queue.new
    worker = nil
    singleton = Daemon.singleton_class
    original_shutdown = singleton.instance_method(:shutdown)

    singleton.send(:define_method, :shutdown) do
      shutdown_threads << Thread.current
    end

    shutdown_thread = nil

    begin
      worker = Thread.new do
        Thread.current[:jid] = 'job-123'
        Daemon.stop
      ensure
        Thread.current[:jid] = nil
      end
      result = worker.value
      shutdown_thread = shutdown_threads.pop
      shutdown_thread.join if shutdown_thread.alive?
    ensure
      singleton.send(:define_method, :shutdown, original_shutdown)
    end

    assert result
    refute_same worker, shutdown_thread
    assert_includes @environment.application.speaker.messages, 'Will shutdown after pending operations'
  ensure
    Daemon.instance_variable_set(:@running, nil)
  end

  def test_stop_runs_shutdown_inline_outside_job_threads
    Librarian.new(container: @environment.container, args: [])
    Daemon.instance_variable_set(:@running, Concurrent::AtomicBoolean.new(true))

    calling_thread = Thread.current
    shutdown_thread = nil
    singleton = Daemon.singleton_class
    original_shutdown = singleton.instance_method(:shutdown)

    singleton.send(:define_method, :shutdown) do
      shutdown_thread = Thread.current
    end

    begin
      result = Daemon.stop
    ensure
      singleton.send(:define_method, :shutdown, original_shutdown)
    end

    assert result
    assert_equal calling_thread, shutdown_thread
    assert_includes @environment.application.speaker.messages, 'Will shutdown after pending operations'
  ensure
    Daemon.instance_variable_set(:@running, nil)
  end

  def test_cli_route_executes_stop_inline_when_pidfile_running
    librarian = Librarian.new(container: @environment.container, args: [])

    Daemon.instance_variable_set(:@running, nil)

    response = { 'status_code' => 200, 'body' => { 'status' => 'stopping' } }
    fake_client = Class.new do
      attr_reader :stop_calls

      def initialize(response)
        @response = response
        @stop_calls = 0
      end

      def stop
        @stop_calls += 1
        @response
      end

      def enqueue(*)
        raise 'Client#enqueue should not be called for daemon stop'
      end
    end.new(response)

    Client.stub(:new, ->(*_) { fake_client }) do
      Daemon.stub(:running?, false) do
        librarian.stub(:pid_status, ->(_pidfile) { :running }) do
          Librarian.route_cmd(%w[daemon stop])
        end
      end
    end

    assert_includes @environment.application.speaker.messages, 'Stop command sent to daemon'
    assert_equal 1, fake_client.stop_calls
  end

end

# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../app/client'
require_relative '../app/daemon'

class LibrarianCliTest < Minitest::Test
  def setup
    super
    reset_librarian_state!
    @environments = []
  end

  def teardown
    @environments.each(&:cleanup)
    reset_librarian_state!
    super
  end

  def test_help_command_dispatches_through_args_dispatch
    env = use_environment

    librarian = Librarian.new(container: env.container, args: ['help'])
    librarian.run!

    dispatches = env.application.args_dispatch.dispatched_commands
    assert_equal 1, dispatches.length
    assert_equal ['help'], dispatches.first[:command]
    assert_includes env.application.speaker.messages, "Welcome to your library assistant!\n\n"
  end

  def test_nested_command_invokes_dispatcher
    env = use_environment

    librarian = Librarian.new(container: env.container, args: ['daemon', 'status'])
    librarian.run!

    dispatches = env.application.args_dispatch.dispatched_commands
    assert_equal 1, dispatches.length
    assert_equal ['daemon', 'status'], dispatches.first[:command]
  end

  def test_daemon_stop_uses_control_endpoint
    env = use_environment
    librarian = Librarian.new(container: env.container, args: ['daemon', 'stop'])

    called = false

    Client.stub(:new, ->(*) { raise 'Client.enqueue should not be used for daemon stop' }) do
      Daemon.stub(:stop, -> { called = true; env.application.speaker.speak_up('Stop command sent to daemon'); true }) do
        librarian.stub(:pid_status, ->(*) { :running }) do
          librarian.run!
        end
      end
    end

    assert called
    assert_includes env.application.speaker.messages, 'Stop command sent to daemon'
  end

  def test_dependencies_are_isolated_per_container
    first_speaker = TestSupport::Fakes::Speaker.new
    first_dispatch = TestSupport::Fakes::ArgsDispatch.new
    env1 = use_environment(speaker: first_speaker, args_dispatch: first_dispatch)

    librarian1 = Librarian.new(container: env1.container, args: ['help'])
    librarian1.run!

    second_speaker = TestSupport::Fakes::Speaker.new
    second_dispatch = TestSupport::Fakes::ArgsDispatch.new
    env2 = use_environment(speaker: second_speaker, args_dispatch: second_dispatch)

    librarian2 = Librarian.new(container: env2.container, args: ['help'])
    librarian2.run!

    assert_equal 1, first_dispatch.dispatched_commands.length
    assert_equal 1, second_dispatch.dispatched_commands.length
    assert_includes first_speaker.messages, "Welcome to your library assistant!\n\n"
    assert_includes second_speaker.messages, "Welcome to your library assistant!\n\n"
  end

  def test_http_errors_from_daemon_are_reported_to_user
    env = use_environment
    librarian = Librarian.new(container: env.container, args: [])

    response = { 'status_code' => 403, 'body' => { 'error' => 'forbidden' } }
    fake_client = Class.new do
      def initialize(response)
        @response = response
      end

      def enqueue(*)
        @response
      end
    end.new(response)

    Client.stub(:new, ->(*) { fake_client }) do
      librarian.stub(:pid_status, ->(*) { :running }) do
        Librarian.route_cmd(['help'])
      end
    end

    assert_includes env.application.speaker.messages,
                    'Daemon rejected the job: forbidden (HTTP 403). Check the control token configuration for the daemon.'
    refute_includes env.application.speaker.messages, 'Command dispatched to daemon'
  end

  private

  def use_environment(**overrides)
    env = build_stubbed_environment(**overrides)
    @environments << env
    env
  end
end

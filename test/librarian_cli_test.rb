# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../app/client'

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

  def test_direct_route_cmd_restores_parent_thread_state
    env = use_environment
    old_application = MediaLibrarian.application
    MediaLibrarian.application = env.application
    Librarian.configure(app: env.application)
    librarian = Librarian.new(container: env.container, args: [])

    thread = Thread.current
    original = thread.keys.each_with_object({}) { |key, memo| memo[key] = thread[key] }
    parent_block = [-> {}]
    parent_email = String.new('parent-email')

    thread[:object] = 'parent-object'
    thread[:block] = parent_block
    thread[:start_time] = Time.now - 5
    thread[:email_msg] = parent_email
    thread[:send_email] = 1
    thread[:jid] = 'parent-jid'
    thread[:queue_name] = 'parent-queue'
    thread[:current_daemon] = 'parent-client'

    before = thread.keys.each_with_object({}) { |key, memo| memo[key] = thread[key] }

    Daemon.stub(:running?, false) do
      librarian.stub(:pid_status, ->(*) { :stopped }) do
        Librarian.route_cmd(['help'])
      end
    end

    after = thread.keys.each_with_object({}) { |key, memo| memo[key] = thread[key] }

    assert_equal before[:object], after[:object], 'expected parent object to remain unchanged'
    assert_same parent_block, after[:block], 'expected parent block array to be restored'
    assert_equal before[:start_time], after[:start_time], 'expected parent start time to persist'
    assert_same parent_email, after[:email_msg], 'expected parent email buffer to be preserved'
    assert_equal before[:send_email], after[:send_email], 'expected parent email flag to remain unchanged'
    assert_equal before[:jid], after[:jid], 'expected parent jid to remain unchanged'
    assert_equal before[:queue_name], after[:queue_name], 'expected parent queue name to remain unchanged'
    assert_equal before[:current_daemon], after[:current_daemon], 'expected parent client to remain unchanged'

    dispatches = env.application.args_dispatch.dispatched_commands
    assert_equal 1, dispatches.length, 'expected nested command to run through ArgsDispatch'
    assert_equal ['help'], dispatches.first[:command]
  ensure
    MediaLibrarian.application = old_application
    original&.each { |key, value| thread[key] = value }
    (thread.keys - original.keys).each { |key| thread[key] = nil }
  end

  private

  def use_environment(**overrides)
    env = build_stubbed_environment(**overrides)
    @environments << env
    env
  end
end

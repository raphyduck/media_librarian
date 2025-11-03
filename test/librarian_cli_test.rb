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

    librarian = Librarian.new(container: env.container, args: ['daemon', 'start'])
    librarian.run!

    dispatches = env.application.args_dispatch.dispatched_commands
    assert_equal 1, dispatches.length
    assert_equal ['daemon', 'start'], dispatches.first[:command]
  end

  def test_daemon_status_cli_uses_status_snapshot_output
    env = use_environment
    MediaLibrarian.application = env.application
    Daemon.configure(app: env.application)
    Client.configure(app: env.application)

    dispatcher = env.application.args_dispatch
    def dispatcher.dispatch(app_name, command, actions, *_rest)
      @dispatched_commands << { app: app_name, command: command.dup, actions: actions }
      Daemon.status
    end

    librarian = Librarian.new(container: env.container, args: ['daemon', 'status'])

    body = {
      'jobs' => [{ 'id' => 'job-1', 'queue' => 'priority', 'status' => 'finished' }],
      'running' => [],
      'queued' => [],
      'finished' => [{ 'id' => 'job-1' }],
      'queues' => [{ 'queue' => 'priority', 'running' => 0, 'queued' => 0, 'finished' => 1, 'total' => 1 }],
      'lock_time' => ''
    }

    fake_client = Minitest::Mock.new
    fake_client.expect(:status, { 'status_code' => 200, 'body' => body })

    original_fetch = Daemon.method(:fetch_function_config)

    Daemon.stub(:running?, false) do
      Daemon.stub(:fetch_function_config, ->(arguments) { arguments == ['daemon', 'status'] ? [1, 'priority'] : original_fetch.call(arguments) }) do
        librarian.stub(:pid_status, ->(*) { :running }) do
          Client.stub(:new, ->(*_) { fake_client }) do
            librarian.run!
          end
        end
      end
    end

    messages = env.application.speaker.messages
    assert_includes messages, 'Total jobs: 1'
    assert_includes messages, 'Queues: priority r:0 q:0 f:1'
    assert_equal 1, dispatcher.dispatched_commands.length
  ensure
    fake_client.verify if defined?(fake_client)
    MediaLibrarian.application = nil
    remove_app_reference(Daemon)
    remove_app_reference(Client)
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

  def test_remote_daemon_job_output_is_displayed_and_capture_requested
    env = use_environment
    librarian = Librarian.new(container: env.container, args: [])

    response = {
      'status_code' => 200,
      'body' => { 'job' => { 'id' => 'job-42', 'output' => 'Hello from daemon' } }
    }
    captured = {}

    fake_client = Class.new do
      def initialize(response, captured)
        @response = response
        @captured = captured
      end

      def enqueue(args, **kwargs)
        @captured[:args] = args
        @captured[:kwargs] = kwargs
        @response
      end
    end.new(response, captured)

    Daemon.stub(:running?, false) do
      librarian.stub(:pid_status, ->(*) { :running }) do
        Client.stub(:new, ->(*) { fake_client }) do
          Librarian.route_cmd(['help'])
        end
      end
    end

    assert_equal ['help'], captured[:args]
    assert_equal true, captured[:kwargs][:capture_output]

    messages = env.application.speaker.messages
    assert_includes messages, 'Hello from daemon'
    assert_includes messages, 'Job job-42 completed'
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

  def test_direct_handle_completed_download_dispatches_email_when_buffered
    env = use_environment
    old_application = MediaLibrarian.application
    MediaLibrarian.application = env.application
    Librarian.configure(app: env.application)
    Librarian.new(container: env.container, args: [])

    library_defined = defined?(Library)
    Object.const_set(:Library, Class.new) unless library_defined
    Library.configure(app: env.application) if Library.respond_to?(:configure)

    env.application.email = {}

    captured = []
    Env.stub(:email_notif?, ->(*) { true }) do
      Report.stub(:sent_out, ->(subject, thread, *rest) {
        captured << {
          subject: subject,
          send_email: thread[:send_email],
          email_msg: thread[:email_msg].dup,
          direct: thread[:direct]
        }
      }) do
        Library.stub(:handle_completed_download, ->(*_) {
          thread = Thread.current
          thread[:email_msg] << 'Ready for email'
          thread[:send_email] = 1
          :ok
        }) do
          Librarian.route_cmd(['Library', 'handle_completed_download'], 1)
        end
      end
    end

    assert_equal 1, captured.length
    record = captured.first
    assert_equal 1, record[:send_email]
    assert_includes record[:email_msg], 'Ready for email'
    assert_equal 1, record[:direct]
  ensure
    MediaLibrarian.application = old_application
    Object.send(:remove_const, :Library) unless library_defined
  end

  private

  def use_environment(**overrides)
    env = build_stubbed_environment(**overrides)
    @environments << env
    env
  end

  def remove_app_reference(klass)
    singleton = klass.singleton_class
    singleton.remove_instance_variable(:@app) if singleton.instance_variable_defined?(:@app)
  end
end

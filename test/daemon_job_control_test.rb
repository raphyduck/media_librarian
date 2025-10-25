# frozen_string_literal: true

require 'thread'
require 'test_helper'
require_relative '../app/daemon'
require_relative '../librarian'
require_relative '../lib/simple_speaker'

class DaemonJobControlTest < Minitest::Test
  class BlockingArgsDispatch < TestSupport::Fakes::ArgsDispatch
    def initialize(started_queue, release_queue)
      super()
      @started_queue = started_queue
      @release_queue = release_queue
    end

    def dispatch(*args)
      @started_queue << Thread.current
      @release_queue.pop
      super
    end
  end

  def setup
    reset_librarian_state!
    @started_queue = Queue.new
    @release_queue = Queue.new
    args_dispatch = BlockingArgsDispatch.new(@started_queue, @release_queue)
    @environment = build_stubbed_environment(args_dispatch: args_dispatch)
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
    Librarian.new(container: @environment.container, args: [])
    Daemon.send(:boot_framework_state)
  end

  def teardown
    @release_queue << nil if @release_queue
    executor = Daemon.send(:instance_variable_get, :@executor)
    executor&.kill
    executor&.wait_for_termination
    Daemon.send(:cleanup)
    @environment&.cleanup
    MediaLibrarian.application = nil
  end

  def test_kill_terminates_running_thread
    job = Daemon.enqueue(args: ['Library', 'block'])
    worker_thread = @started_queue.pop

    assert worker_thread.alive?, 'expected the job to be running before requesting cancellation'

    Daemon.kill(jid: job.id)

    assert_equal worker_thread, worker_thread.join(1), 'expected the worker thread to stop promptly after kill'
    refute worker_thread.alive?
    assert_equal :cancelled, job.status
    assert job.finished_at
    assert_nil job.worker_thread
    assert_equal 'Cancelled', job.error
  end

  def test_thread_locals_restored_after_inline_child_execution
    configure_single_worker_daemon!

    parent_snapshots = {}
    child_snapshot = nil
    worker_thread = nil

    Librarian.stub(:run_command, lambda do |args, *_rest, &block|
      thread = Thread.current
      worker_thread ||= thread

      case args.first
      when 'parent'
        parent_snapshots[:before] = capture_thread_locals(thread)
        child_job = Daemon.enqueue(args: ['child'], client: 'child-client', child: 1, parent_thread: thread)
        parent_snapshots[:after] = capture_thread_locals(thread)
      when 'child'
        child_snapshot = capture_thread_locals(thread)
      end

      block&.call
    end) do
      job = Daemon.enqueue(args: ['parent'], client: 'parent-client')
      job.future.value!
    end

    assert parent_snapshots[:before], 'expected parent job to capture thread locals before spawning child'
    assert child_snapshot, 'expected child job to run'
    assert_equal parent_snapshots[:before], parent_snapshots[:after], 'parent thread locals should be restored after child job'
    assert_equal 'parent-client', parent_snapshots[:before][:current_daemon]
    assert_equal 'child-client', child_snapshot[:current_daemon]
    refute_same worker_thread, child_snapshot[:parent], 'child thread parent should not reference the worker thread itself'
    refute_equal parent_snapshots[:before][:jid], child_snapshot[:jid]
  end

  def test_inline_child_logging_restores_parent_log_buffer
    configure_single_worker_daemon!
    @environment.application.speaker = SimpleSpeaker::Speaker.new

    parent_log_state = {}
    child_log_buffer = nil

    Librarian.stub(:run_command, lambda do |args, *_rest, &block|
      thread = Thread.current

      case args.first
      when 'parent-log'
        parent_log_state[:before] = thread[:log_msg]
        Daemon.enqueue(args: ['child-log'], child: 1, parent_thread: thread)
        parent_log_state[:after_child] = thread[:log_msg]
        @environment.application.speaker.speak_up('parent output')
        parent_log_state[:after_parent_log] = thread[:log_msg]
      when 'child-log'
        child_log_buffer = thread[:log_msg]
        @environment.application.speaker.speak_up('child output')
      end

      block&.call
    end) do
      job = Daemon.enqueue(args: ['parent-log'])
      job.future.value!
    end

    assert_nil parent_log_state[:before], 'expected parent thread to flush immediately before spawning child'
    assert_kind_of String, child_log_buffer, 'expected child job to have a log buffer'
    assert_nil parent_log_state[:after_child], 'expected parent thread log buffer to be cleared after child job'
    assert_nil parent_log_state[:after_parent_log], 'expected parent to keep flushing immediately after child log output'
  end

  private

  def configure_single_worker_daemon!
    executor = Daemon.send(:instance_variable_get, :@executor)
    executor&.kill
    executor&.wait_for_termination
    Daemon.send(:cleanup)
    @environment.application.workers_pool_size = 1
    @environment.container.workers_pool_size = 1
    Daemon.send(:boot_framework_state)
  end

  def capture_thread_locals(thread)
    {
      current_daemon: thread[:current_daemon],
      parent: thread[:parent],
      jid: thread[:jid],
      queue_name: thread[:queue_name],
      log_msg: thread[:log_msg]
    }
  end
end

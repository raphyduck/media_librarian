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
    executor = Daemon.send(:instance_variable_get, :@executor)
    executor&.kill
    executor&.wait_for_termination
    Daemon.send(:cleanup)
    @environment.application.workers_pool_size = 1
    @environment.container.workers_pool_size = 1
    Daemon.send(:boot_framework_state)

    parent_snapshots = {}
    child_snapshot = nil
    worker_thread = nil

    capture_locals = lambda do |thread|
      {
        current_daemon: thread[:current_daemon],
        parent: thread[:parent],
        jid: thread[:jid],
        queue_name: thread[:queue_name],
        log_msg: thread[:log_msg]
      }
    end

    Librarian.stub(:run_command, lambda do |args, *_rest, &block|
      thread = Thread.current
      worker_thread ||= thread

      case args.first
      when 'parent'
        parent_snapshots[:before] = capture_locals.call(thread)
        child_job = Daemon.enqueue(args: ['child'], client: 'child-client', child: 1, parent_thread: thread)
        parent_snapshots[:after] = capture_locals.call(thread)
      when 'child'
        child_snapshot = capture_locals.call(thread)
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

  def test_nested_capture_output_preserves_parent_buffer
    executor = Daemon.send(:instance_variable_get, :@executor)
    executor&.kill
    executor&.wait_for_termination
    Daemon.send(:cleanup)
    @environment.application.workers_pool_size = 1
    @environment.container.workers_pool_size = 1
    Daemon.send(:boot_framework_state)

    child_job = nil
    outer_output = nil
    outer_thread = nil
    child_thread = nil

    Librarian.stub(:run_command, lambda do |args, *_rest, &block|
      case args.first
      when 'outer'
        outer_thread ||= Thread.current
        buffer = Thread.current[:captured_output]
        buffer << "outer start\n"
        child_job = Daemon.enqueue(args: ['inner'], capture_output: true, child: 1, parent_thread: Thread.current)
        buffer << "outer end\n"
      when 'inner'
        child_thread = Thread.current
        Thread.current[:captured_output] << "inner body\n"
      end

      block&.call
    end) do
      outer_job = Daemon.enqueue(args: ['outer'], capture_output: true)
      outer_job.future.value!
      outer_output = outer_job.output
    end

    refute_nil child_job, 'expected child job to be enqueued'
    child_job.future.value!
    assert_equal "outer start\nouter end\n", outer_output
    assert_equal "inner body\n", child_job.output
    assert_same outer_thread, child_thread, 'expected child job to run inline on the outer worker thread'
  end

  def test_restores_nil_parent_after_worker_seeded_with_self_parent
    executor = Daemon.send(:instance_variable_get, :@executor)
    executor&.kill
    executor&.wait_for_termination
    Daemon.send(:cleanup)
    @environment.application.workers_pool_size = 1
    @environment.container.workers_pool_size = 1
    Daemon.send(:boot_framework_state)

    worker_thread = nil
    child_job = nil

    Librarian.stub(:run_command, lambda do |args, *_rest, &block|
      thread = Thread.current
      worker_thread ||= thread

      case args.first
      when 'parent'
        child_job = Daemon.enqueue(args: ['child'], child: 1, parent_thread: thread)
      end

      block&.call
    end) do
      seed_job = Daemon.enqueue(args: ['seed'])
      seed_job.future.value!

      worker_thread[:parent] = worker_thread

      parent_job = Daemon.enqueue(args: ['parent'])
      parent_job.future.value!

      assert_equal :finished, parent_job.status
    end

    refute_nil worker_thread, 'expected to capture worker thread from seed job'
    refute_nil child_job, 'expected child job to be enqueued'
    child_job.future.value!
    assert_equal :finished, child_job.status
    assert_nil worker_thread[:parent], 'expected worker thread parent to be cleared after jobs complete'
  end

  def test_inline_child_logging_restores_parent_immediate_flush
    executor = Daemon.send(:instance_variable_get, :@executor)
    executor&.kill
    executor&.wait_for_termination
    Daemon.send(:cleanup)

    @environment.application.speaker = SimpleSpeaker::Speaker.new
    speaker = @environment.application.speaker
    captured_output = []
    speaker.define_singleton_method(:daemon_send) do |str|
      captured_output << str.to_s
    end

    @environment.application.workers_pool_size = 1
    @environment.container.workers_pool_size = 1
    Daemon.send(:boot_framework_state)

    parent_log_states = {}
    job = nil
    child_status = nil

    Librarian.stub(:run_command, lambda do |args, *_rest, &block|
      thread = Thread.current

      case args.first
      when 'parent'
        parent_log_states[:before_child] = thread[:log_msg]
        child_job = Daemon::Job.new(
          id: Daemon.job_id,
          queue: 'child',
          args: ['child'],
          task: 'child',
          client: 'child-client',
          env_flags: {},
          parent_thread: thread,
          child: 1,
          status: :queued,
          capture_output: false
        )
        child_result = Daemon.send(:execute_job, child_job)
        Daemon.send(:finalize_job, child_job, child_result, nil)
        child_status = child_job.status
        parent_log_states[:after_child] = thread[:log_msg]
        MediaLibrarian.app.speaker.speak_up('parent message')
        parent_log_states[:after_log] = thread[:log_msg]
      when 'child'
        MediaLibrarian.app.speaker.speak_up('child message')
        :child_result
      end

      block&.call
    end) do
      job = Daemon.enqueue(args: ['parent'])
      job.future.value!
    end

    assert job, 'expected parent job to be enqueued'
    assert_equal :finished, job.status
    assert_equal :finished, child_status, 'expected child job to finish inline'
    assert_nil parent_log_states[:before_child], 'expected parent log buffer to start nil'
    assert_nil parent_log_states[:after_child], 'expected inline child to preserve nil parent log buffer'
    assert_nil parent_log_states[:after_log], 'expected parent log buffer to remain nil after logging'
    assert_includes captured_output, 'parent message', 'expected parent log message to flush immediately'
  end
end

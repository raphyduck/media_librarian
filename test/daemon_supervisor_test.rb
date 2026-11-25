# frozen_string_literal: true

require 'thread'
require 'test_helper'
require_relative '../app/daemon'
require_relative '../librarian'
require_relative '../lib/simple_speaker'

class DaemonSupervisorTest < Minitest::Test
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

  def test_orphan_needs_two_sweeps
    job = orphan_candidate

    Daemon.send(:sweep_stuck_jobs)
    assert job.running?, 'expected the first sweep to only mark the job as a suspect'

    Daemon.send(:sweep_stuck_jobs)
    assert_equal :failed, job.status
    assert_equal 'orphaned', job.error
    assert job.finished_at
  end

  def test_live_worker_not_orphaned
    worker = Thread.new { sleep }
    job = register_running_job(worker)

    begin
      Daemon.send(:sweep_stuck_jobs)
      Daemon.send(:sweep_stuck_jobs)
      assert job.running?, 'expected a job with a live worker to keep running'
    ensure
      worker.kill
      worker.join
    end
  end

  def test_hard_deadline_fails_job
    worker = Thread.new { sleep }
    job = register_running_job(worker)
    job.deadline = Time.now - Daemon::HARD_TIMEOUT_GRACE_SECONDS - 1

    begin
      Daemon.send(:sweep_stuck_jobs)
      assert_equal :failed, job.status
      assert_equal 'timeout', job.error.to_s
    ensure
      worker.kill
      worker.join
    end
  end

  def test_rebuild_executor_requeues_waiting_jobs
    @environment.application.workers_pool_size = 1
    @environment.container.workers_pool_size = 1
    Daemon.send(:cleanup)
    Daemon.send(:boot_framework_state)
    old_executor = Daemon.send(:instance_variable_get, :@executor)

    spoken = []
    @environment.application.speaker.define_singleton_method(:speak_up) do |str, *_rest|
      spoken << str.to_s
    end

    blocking = Daemon.enqueue(args: ['Library', 'block'])
    @started_queue.pop
    waiting = Daemon.enqueue(args: %w[Library block])

    Daemon.send(:rebuild_executor, 'test')

    refute_same old_executor, Daemon.send(:instance_variable_get, :@executor)
    assert_equal :failed, blocking.status
    assert_equal 'executor restarted', blocking.error

    @started_queue.pop
    @release_queue << nil
    waiting.future.wait(5)
    assert_equal :finished, waiting.status

    assert(spoken.any? { |line| line.include?('[supervisor] thread') }, 'expected the thread dump in the journal')
  end

  def test_stall_detection
    @environment.application.workers_pool_size = 1
    @environment.container.workers_pool_size = 1
    Daemon.send(:cleanup)
    Daemon.send(:boot_framework_state)

    queued = Daemon::Job.new(
      id: Daemon.job_id, queue: 'q', args: ['x'], task: 'x', status: :queued,
      child: 0, capture_output: false, future: Concurrent::Promises.resolvable_future
    )
    Daemon.send(:job_registry)[queued.id] = queued
    Daemon.instance_variable_set(:@last_execution, {})
    Daemon.instance_variable_set(:@last_job_progress_at, Time.now - 3600)

    assert Daemon.send(:executor_stalled?), 'expected a stall when a posted job waits and the pool is idle'

    running_worker = Thread.new { sleep }
    running = Daemon::Job.new(
      id: Daemon.job_id, queue: 'q', args: ['y'], task: 'y', status: :running,
      child: 0, capture_output: false, worker_thread: running_worker
    )
    Daemon.send(:job_registry)[running.id] = running
    begin
      refute Daemon.send(:executor_stalled?), 'expected no stall when the pool is busy'
    ensure
      running_worker.kill
      running_worker.join
    end

    Daemon.send(:job_registry).delete(running.id)
    Daemon.instance_variable_set(:@last_job_progress_at, Time.now)
    refute Daemon.send(:executor_stalled?), 'expected no stall when progress is recent'
  end

  def test_supervisor_idle_during_shutdown
    Daemon.send(:restart_requested_flag).make_true
    Daemon.stub(:rebuild_executor, ->(*) { raise 'rebuild must not run during shutdown' }) do
      Daemon.send(:supervise_executor)
    end
  ensure
    Daemon.send(:restart_requested_flag).make_false
  end

  private

  def orphan_candidate
    dead = Thread.new {}
    dead.join
    register_running_job(dead)
  end

  def register_running_job(worker)
    job = Daemon::Job.new(
      id: Daemon.job_id, queue: 'q', args: ['x'], task: 'x', status: :running,
      child: 0, capture_output: false, worker_thread: worker, started_at: Time.now
    )
    Daemon.send(:job_registry)[job.id] = job
    job
  end
end

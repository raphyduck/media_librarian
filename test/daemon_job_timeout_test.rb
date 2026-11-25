# frozen_string_literal: true

require 'thread'
require 'test_helper'
require_relative '../app/daemon'
require_relative '../librarian'
require_relative '../lib/simple_speaker'

class DaemonJobTimeoutTest < Minitest::Test
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

  def boot_with_timeout(seconds, pool_size: 1)
    @environment.container.config = { 'daemon' => { 'job_timeout_seconds' => seconds } } unless seconds.nil?
    @environment.application.workers_pool_size = pool_size
    @environment.container.workers_pool_size = pool_size
    Daemon.send(:boot_framework_state)
  end

  def test_job_exceeding_timeout_is_failed_and_worker_survives
    boot_with_timeout(1)

    job = Daemon.enqueue(args: %w[Library block])
    worker_thread = @started_queue.pop
    job.future.wait(5)

    assert_equal :failed, job.status
    assert_equal 'timeout', job.error.to_s
    assert job.finished_at, 'expected the timed-out job to be finalized'
    assert worker_thread.alive?, 'expected the pool thread to survive the timeout'

    second = Daemon.enqueue(args: %w[Library block])
    @started_queue.pop
    @release_queue << nil
    second.future.wait(5)

    assert_equal :finished, second.status, 'expected the pool to keep running jobs after a timeout'
  end

  def test_continuous_job_is_exempt_from_timeout
    boot_with_timeout(1)

    job = Daemon.enqueue(args: ['Library', 'block', '--continuous=1'])
    @started_queue.pop
    sleep 1.5

    assert job.running?, 'expected a continuous job to outlive the timeout'
    assert_nil job.deadline

    @release_queue << nil
    job.future.wait(5)
    assert_equal :finished, job.status
  end

  def test_zero_timeout_disables_limit
    boot_with_timeout(0)

    job = Daemon.enqueue(args: %w[Library block])
    @started_queue.pop
    sleep 1.5

    assert job.running?, 'expected no timeout when job_timeout_seconds is 0'
    assert_nil job.deadline

    @release_queue << nil
    job.future.wait(5)
    assert_equal :finished, job.status
  end
end

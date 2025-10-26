# frozen_string_literal: true

require 'test_helper'
require_relative '../app/daemon'

class DaemonQueueConcurrencyTest < Minitest::Test
  def setup
    reset_librarian_state!
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
    Daemon.instance_variable_set(:@queue_limits, Concurrent::Hash.new)
    Daemon.instance_variable_set(:@jobs, {})
    Daemon.instance_variable_set(:@template_cache, nil)
    Daemon.instance_variable_set(:@job_children, Concurrent::Hash.new { |h, k| h[k] = Concurrent::Array.new })
    Daemon.instance_variable_set(:@running, Concurrent::AtomicBoolean.new(true))
    Daemon.instance_variable_set(:@executor, nil)
  end

  def teardown
    Daemon.instance_variable_set(:@queue_limits, nil)
    Daemon.instance_variable_set(:@jobs, nil)
    Daemon.instance_variable_set(:@template_cache, nil)
    Daemon.instance_variable_set(:@job_children, nil)
    Daemon.instance_variable_set(:@running, nil)
    Daemon.instance_variable_set(:@executor, nil)
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def test_queue_busy_respects_configured_concurrency
    queue = 'continuous-task'
    Daemon.send(:queue_limits)[queue] = 2

    refute Daemon.send(:queue_busy?, queue), 'queues should allow scheduling when under the limit'

    job1 = build_running_job(queue)
    Daemon.instance_variable_set(:@jobs, { '1' => job1 })
    refute Daemon.send(:queue_busy?, queue), 'queues with capacity should not be busy'

    job2 = build_running_job(queue)
    Daemon.instance_variable_set(:@jobs, { '1' => job1, '2' => job2 })
    assert Daemon.send(:queue_busy?, queue), 'queue should report busy once limit is reached'
  end

  def test_queue_busy_defaults_to_single_worker
    queue = 'default'
    job = build_running_job(queue)
    Daemon.instance_variable_set(:@jobs, { '1' => job })

    assert Daemon.send(:queue_busy?, queue), 'queues without configuration should default to 1'
  end

  def test_enqueue_retries_until_executor_accepts_job
    executor = FakeExecutor.new
    Daemon.instance_variable_set(:@executor, executor)
    LibraryBus.initialize_queue(Thread.current)
    Thread.current[:jid] = 'parent-test'

    attempts = 0
    results = []
    payload = ['payload']
    future_factory = lambda do |provided_executor, &block|
      attempts += 1
      assert_same executor, provided_executor
      raise Concurrent::RejectedExecutionError if attempts < 3

      FakeFuture.new do
        value = block.call
        results << value
        value
      end
    end

    sleep_stub = lambda do |interval|
      executor.capacity = 1 if interval.to_f < 1
    end

    Librarian.stub(:run_command, ->(*_args, &block) { block&.call }) do
      Daemon.stub(:sleep, sleep_stub) do
        Concurrent::Promises.stub(:future_on, future_factory) do
          job = Daemon.enqueue(
            args: %w[Library parse_media],
            queue: 'test',
            task: 'test',
            internal: 1,
            parent_thread: Thread.current
          ) do
            LibraryBus.put_in_queue(payload)
            'job-result'
          end

          refute_nil job, 'enqueue should return a job'
          job.future.wait
          assert_equal [payload], Daemon.consolidate_children(Thread.current)
          assert_equal 3, attempts
          assert_equal ['job-result'], results
          assert_equal :finished, job.status
          assert_equal 'job-result', job.result
        end
      end
    end
  ensure
    Thread.current[:jid] = nil
  end

  private

  def build_running_job(queue)
    Daemon::Job.new(id: 'job', queue: queue, status: :running, finished_at: nil)
  end

  class FakeExecutor
    attr_accessor :capacity

    def initialize
      @capacity = 0
    end

    def remaining_capacity
      @capacity
    end
  end

  class FakeFuture
    def initialize(&block)
      @block = block
      @callbacks = { fulfilled: [], rejected: [] }
      @executed = false
    end

    def on_fulfillment!(&block)
      if @executed && !@error
        block.call(@value)
      else
        @callbacks[:fulfilled] << block
      end
      self
    end

    def on_rejection!(&block)
      if @executed && @error
        block.call(@error)
      else
        @callbacks[:rejected] << block
      end
      self
    end

    def wait
      execute
      self
    end

    def value!
      execute
      raise @error if @error

      @value
    end

    def cancelled?
      false
    end

    def cancel(*)
      false
    end

    private

    def execute
      return if @executed

      begin
        @value = @block.call
      rescue => e
        @error = e
      ensure
        @executed = true
      end

      callbacks = @error ? @callbacks[:rejected] : @callbacks[:fulfilled]
      callbacks.each { |callback| callback.call(@error || @value) }
    end
  end
end

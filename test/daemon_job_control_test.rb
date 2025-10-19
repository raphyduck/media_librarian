# frozen_string_literal: true

require 'thread'
require 'test_helper'
require_relative '../app/daemon'
require_relative '../librarian'

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
end

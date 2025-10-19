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
  end

  def teardown
    Daemon.instance_variable_set(:@queue_limits, nil)
    Daemon.instance_variable_set(:@jobs, nil)
    Daemon.instance_variable_set(:@template_cache, nil)
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

  private

  def build_running_job(queue)
    Daemon::Job.new(id: 'job', queue: queue, status: :running, finished_at: nil)
  end
end

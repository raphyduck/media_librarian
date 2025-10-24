# frozen_string_literal: true

require 'test_helper'
require_relative '../app/daemon'

class DaemonStatusSnapshotTest < Minitest::Test
  def setup
    reset_librarian_state!
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
    Daemon.instance_variable_set(:@jobs, {})
    Daemon.instance_variable_set(:@job_children, Concurrent::Hash.new { |h, k| h[k] = Concurrent::Array.new })
  end

  def teardown
    Daemon.instance_variable_set(:@jobs, nil)
    Daemon.instance_variable_set(:@job_children, nil)
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def test_status_snapshot_includes_all_jobs_and_queue_metrics
    finished_job = Daemon::Job.new(id: 'finished', queue: 'done', status: :finished, finished_at: Time.now)
    parent_job = Daemon::Job.new(id: 'parent', queue: 'alpha', status: :running, finished_at: nil)
    child_job = Daemon::Job.new(id: 'child', queue: 'alpha', status: :running, finished_at: nil, parent_job_id: 'parent')
    queued_job = Daemon::Job.new(id: 'queued', queue: 'beta', status: :queued, finished_at: nil)

    jobs = {
      parent_job.id => parent_job,
      child_job.id => child_job,
      finished_job.id => finished_job,
      queued_job.id => queued_job
    }
    Daemon.instance_variable_set(:@jobs, jobs)

    children = Concurrent::Hash.new { |h, k| h[k] = Concurrent::Array.new }
    children[parent_job.id] << child_job.id
    Daemon.instance_variable_set(:@job_children, children)

    snapshot = Daemon.status_snapshot

    assert_equal %w[parent child queued finished], snapshot[:jobs].map(&:id)
    assert_equal %w[parent child], snapshot[:running].map(&:id)
    assert_equal ['queued'], snapshot[:queued].map(&:id)
    assert_equal ['finished'], snapshot[:finished].map(&:id)

    queues = snapshot[:queues]
    assert_equal(%w[alpha beta done], queues.map { |entry| entry['queue'] })
    alpha = queues.find { |entry| entry['queue'] == 'alpha' }
    assert_equal 2, alpha['running']
    assert_equal 0, alpha['queued']
    assert_equal 0, alpha['finished']
    assert_equal 2, alpha['total']
    beta = queues.find { |entry| entry['queue'] == 'beta' }
    assert_equal 0, beta['running']
    assert_equal 1, beta['queued']
    done = queues.find { |entry| entry['queue'] == 'done' }
    assert_equal 1, done['finished']

    parent_payload = Daemon.send(:serialize_job, parent_job)
    assert_equal 'alpha', parent_payload['queue']
    assert_equal 1, parent_payload['children']
    assert_equal ['child'], parent_payload['children_ids']

    child_payload = Daemon.send(:serialize_job, child_job)
    assert_equal 'parent', child_payload['parent_id']
  end
end

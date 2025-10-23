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

  def test_status_snapshot_only_reports_running_jobs
    finished_job = Daemon::Job.new(id: 'finished', queue: 'done', status: :finished, finished_at: Time.now)
    parent_job = Daemon::Job.new(id: 'parent', queue: 'alpha', status: :running, finished_at: nil)
    child_job = Daemon::Job.new(id: 'child', queue: 'alpha', status: :running, finished_at: nil, parent_job_id: 'parent')

    jobs = {
      parent_job.id => parent_job,
      child_job.id => child_job,
      finished_job.id => finished_job
    }
    Daemon.instance_variable_set(:@jobs, jobs)

    children = Concurrent::Hash.new { |h, k| h[k] = Concurrent::Array.new }
    children[parent_job.id] << child_job.id
    Daemon.instance_variable_set(:@job_children, children)

    snapshot = Daemon.status_snapshot

    assert_equal %w[parent child].sort, snapshot[:jobs].map(&:id).sort

    parent_payload = Daemon.send(:serialize_job, parent_job)
    assert_equal 'alpha', parent_payload['queue']
    assert_equal 1, parent_payload['children']
    assert_equal ['child'], parent_payload['children_ids']

    child_payload = Daemon.send(:serialize_job, child_job)
    assert_equal 'parent', child_payload['parent_id']
  end
end

# frozen_string_literal: true

require 'test_helper'
require_relative '../app/daemon'

class FlippingJob
  attr_reader :id, :queue, :created_at
  attr_accessor :status, :finished_at

  def initialize(id:, queue:, created_at: Time.now)
    @id = id
    @queue = queue
    @created_at = created_at
    @status = :running
    @finished_at = nil
    @toggled = false
  end

  def running?
    return false if @toggled

    @toggled = true
    self.status = :finished
    self.finished_at = Time.now
    true
  end

  def finished?
    !!finished_at || %i[finished failed cancelled].include?(status)
  end
end

class DaemonStatusSnapshotTest < Minitest::Test
  def setup
    reset_librarian_state!
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
    Daemon.instance_variable_set(:@jobs, {})
    Daemon.instance_variable_set(:@job_children, Concurrent::Hash.new { |h, k| h[k] = Concurrent::Array.new })
    Daemon.instance_variable_set(:@daemon_started_at, nil)
    Daemon.instance_variable_set(:@process_memory, nil)
  end

  def teardown
    Daemon.instance_variable_set(:@jobs, nil)
    Daemon.instance_variable_set(:@job_children, nil)
    Daemon.instance_variable_set(:@daemon_started_at, nil)
    Daemon.instance_variable_set(:@process_memory, nil)
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

    assert_kind_of Hash, snapshot[:resources]
    assert snapshot.key?(:started_at)
    assert snapshot.key?(:uptime_seconds)
  end

  def test_status_snapshot_prevents_double_counting_flipping_jobs
    flipping_job = FlippingJob.new(id: 'flip', queue: 'alpha')
    Daemon.instance_variable_set(:@jobs, { flipping_job.id => flipping_job })

    snapshot = Daemon.status_snapshot

    running_ids = snapshot[:running].map(&:id)
    finished_ids = snapshot[:finished].map(&:id)
    queued_ids = snapshot[:queued].map(&:id)

    assert_equal(['flip'], snapshot[:jobs].map(&:id))
    assert_equal 1, [running_ids.include?('flip'), finished_ids.include?('flip'), queued_ids.include?('flip')].count(true)
    assert_empty(running_ids & finished_ids)
    assert_empty(running_ids & queued_ids)
    assert_empty(finished_ids & queued_ids)
  end

  def test_status_snapshot_includes_daemon_metrics
    now = Time.now.utc
    Daemon.instance_variable_set(:@daemon_started_at, now - 10)

    fake_memory = Struct.new(:mb).new(256.5)

    snapshot = nil
    Daemon.stub(:process_cpu_time, 5.0) do
      Daemon.stub(:process_memory, fake_memory) do
        Time.stub(:now, now) do
          snapshot = Daemon.status_snapshot
        end
      end
    end

    assert_in_delta 10.0, snapshot[:uptime_seconds], 1e-6
    assert_in_delta 5.0, snapshot[:resources]['cpu_time_seconds'], 1e-6
    assert_in_delta 50.0, snapshot[:resources]['cpu_percent'], 1e-6
    assert_in_delta 256.5, snapshot[:resources]['rss_mb'], 1e-6
    assert_in_delta((now - 10).to_f, snapshot[:started_at].to_f, 1e-6)
  end

  def test_build_snapshot_from_hashes_restores_metadata
    now = Time.now.utc
    payload = {
      'jobs' => [],
      'running' => [],
      'queued' => [],
      'finished' => [],
      'queues' => [],
      'started_at' => now.iso8601,
      'uptime_seconds' => 42.5,
      'resources' => {
        'cpu_time_seconds' => 3.2,
        'cpu_percent' => 12.5,
        'rss_mb' => 128.4
      }
    }

    snapshot = Daemon.send(:build_snapshot_from_hashes, payload)

    assert_kind_of Time, snapshot[:started_at]
    assert_in_delta 42.5, snapshot[:uptime_seconds], 1e-6
    assert_equal 3.2, snapshot[:resources]['cpu_time_seconds']
    assert_equal 12.5, snapshot[:resources]['cpu_percent']
    assert_equal 128.4, snapshot[:resources]['rss_mb']
  end
end

# frozen_string_literal: true

require 'minitest/mock'
require 'test_helper'
require_relative '../app/daemon'

class DaemonSchedulerDedupTest < Minitest::Test
  def setup
    reset_librarian_state!
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
    Thread.current[:current_daemon] = :test_client
    @scheduler_name = 'dedup_scheduler'
    Daemon.instance_variable_set(:@jobs, Concurrent::Hash.new)
    Daemon.instance_variable_set(:@running, Concurrent::AtomicBoolean.new(true))
    Daemon.instance_variable_set(:@template_cache, nil)
    Daemon.instance_variable_set(:@last_execution, {})
    Daemon.instance_variable_set(:@queue_limits, Concurrent::Hash.new)
  end

  def teardown
    Thread.current[:current_daemon] = nil
    cleanup_daemon_state
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def test_two_ticks_create_single_queued_entry
    write_template('periodic' => monitor_entry)
    enqueued = []

    stub_schedule(enqueued) do
      Daemon.schedule(@scheduler_name)
      Daemon.schedule(@scheduler_name)
    end

    assert_equal 1, enqueued.length, 'expected a second tick to see the queued job and not enqueue again'
  end

  def test_running_job_blocks_new_periodic
    write_template('periodic' => monitor_entry)
    register_job(status: :running)
    enqueued = []

    stub_schedule(enqueued) { Daemon.schedule(@scheduler_name) }

    assert_empty enqueued
  end

  def test_finished_job_allows_new_periodic
    write_template('periodic' => monitor_entry)
    register_job(status: :finished, finished_at: Time.now)
    enqueued = []

    stub_schedule(enqueued) { Daemon.schedule(@scheduler_name) }

    assert_equal 1, enqueued.length
  end

  def test_continuous_not_reenqueued_while_queued
    write_template('continuous' => { 'continuous_task' => { 'command' => 'monitor.run' } })
    register_job(status: :queued, task: 'continuous_task', queue: 'continuous_task')
    enqueued = []

    stub_schedule(enqueued) { Daemon.schedule(@scheduler_name) }

    assert_empty enqueued
  end

  private

  def cleanup_daemon_state
    %i[@running @template_cache @last_execution @queue_limits @jobs].each do |name|
      Daemon.instance_variable_set(name, nil)
    end
  end

  def monitor_entry
    {
      'monitor' => {
        'command' => 'monitor_torrent_client',
        'every' => '10 minutes'
      }
    }
  end

  def write_template(sections)
    template = sections.transform_values { |entries| entries }
    path = File.join(@environment.application.template_dir, "#{@scheduler_name}.yml")
    File.write(path, template.to_yaml)
  end

  def register_job(status:, finished_at: nil, task: 'monitor', queue: 'torrenting')
    job = Daemon::Job.new(
      id: Daemon.job_id,
      queue: queue,
      args: [task],
      task: task,
      internal: 0,
      client: :test_client,
      env_flags: {},
      child: 0,
      status: status,
      finished_at: finished_at,
      capture_output: false
    )
    Daemon.send(:job_registry)[job.id] = job
  end

  def stub_schedule(enqueued, &block)
    recorder = lambda do |**params|
      enqueued << params
      job = Daemon::Job.new(
        id: Daemon.job_id,
        queue: params[:queue],
        args: params[:args],
        task: params[:task],
        internal: 0,
        client: :test_client,
        env_flags: {},
        child: 0,
        status: :queued,
        capture_output: false
      )
      Daemon.send(:job_registry)[job.id] = job
    end

    Utils.stub(:timeperiod_to_sec, ->(_value) { 600 }) do
      Daemon.stub(:should_run_periodic?, ->(*) { true }) do
        Daemon.stub(:enqueue, recorder, &block)
      end
    end
  end
end

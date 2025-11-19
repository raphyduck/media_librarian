# frozen_string_literal: true

require 'test_helper'
require_relative '../app/daemon'

class DaemonSchedulerCalendarTest < Minitest::Test
  def setup
    reset_librarian_state!
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
    Thread.current[:current_daemon] = :test_client
    @scheduler_name = 'calendar_scheduler'
    write_scheduler_template
  end

  def teardown
    Thread.current[:current_daemon] = nil
    cleanup_daemon_state
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def test_calendar_refresh_frequency_uses_configuration_interval
    apply_calendar_config(refresh_every: '2 hours')
    reset_daemon_schedule_state

    recorded_frequency = nil
    enqueued = []

    Utils.stub(:timeperiod_to_sec, method(:timeperiod_to_sec_stub)) do
      Daemon.stub(:should_run_periodic?, ->(_task, frequency) { recorded_frequency = frequency; true }) do
        Daemon.stub(:enqueue, ->(**params) { enqueued << params }) do
          Daemon.schedule(@scheduler_name)
        end
      end
    end

    assert_equal 7_200, recorded_frequency
    assert_equal 1, enqueued.length
    assert_equal %w[calendar refresh_feed], enqueued.first[:args].first(2)
  end

  private

  def write_scheduler_template
    template = {
      'periodic' => {
        'calendar_feed_refresh' => {
          'command' => 'calendar.refresh_feed',
          'every' => '1 hours'
        }
      }
    }
    path = File.join(@environment.application.template_dir, "#{@scheduler_name}.yml")
    File.write(path, template.to_yaml)
  end

  def apply_calendar_config(refresh_every: '12 hours')
    config = {
      'daemon' => { 'workers_pool_size' => 1, 'queue_slots' => 1 },
      'calendar' => {
        'refresh_every' => refresh_every,
        'refresh_days' => 10,
        'refresh_limit' => 25,
        'providers' => 'imdb|trakt'
      }
    }
    @environment.container.reload_config!(config)
  end

  def reset_daemon_schedule_state
    Daemon.instance_variable_set(:@template_cache, nil)
    Daemon.instance_variable_set(:@last_execution, {})
    Daemon.instance_variable_set(:@queue_limits, Concurrent::Hash.new)
    Daemon.instance_variable_set(:@running, Concurrent::AtomicBoolean.new(true))
  end

  def cleanup_daemon_state
    %i[@running @template_cache @last_execution @queue_limits].each do |name|
      Daemon.instance_variable_set(name, nil)
    end
  end

  def timeperiod_to_sec_stub(argument)
    case argument
    when '2 hours'
      7_200
    when '1 hours'
      3_600
    when Integer
      argument
    else
      0
    end
  end
end

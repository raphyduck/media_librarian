# frozen_string_literal: true

require 'socket'
require 'timeout'
require 'yaml'
require 'test_helper'
require_relative '../app/daemon'
require_relative '../app/client'

class DaemonIntegrationTest < Minitest::Test
  def setup
    reset_librarian_state!
  end

  def teardown
    Daemon.stop if Daemon.running?
    @daemon_thread&.join
    @environment&.cleanup
    MediaLibrarian.application = nil
  end

  def test_http_jobs_execute_to_completion
    boot_daemon_environment

    response = Client.new.enqueue(['Library', 'noop'], wait: true)
    assert_equal 200, response['status_code']

    job = response.fetch('body').fetch('job')
    assert_equal 'finished', job['status']
    assert_equal ['Library', 'noop'], recorded_commands.first[:command]

    status = Client.new.status
    assert_equal 200, status['status_code']
    jobs = status.fetch('body')
    assert_equal 1, jobs.size
    assert_equal job['id'], jobs.first['id']
  end

  def test_jobs_can_be_inspected_and_daemon_stops_cleanly
    boot_daemon_environment

    response = Client.new.enqueue(['Library', 'noop'], wait: false)
    job = response.fetch('body').fetch('job')
    wait_for_job(job['id'])

    lookup = Client.new.job_status(job['id'])
    assert_equal 200, lookup['status_code']
    assert_equal job['id'], lookup.fetch('body').fetch('id')

    stop_response = Client.new.stop
    assert_equal 200, stop_response['status_code']
    @daemon_thread.join
    refute Daemon.running?
  end

  def test_reload_refreshes_configuration_and_scheduler
    scheduler_name = 'reload_scheduler'

    boot_daemon_environment(scheduler: scheduler_name) do
      write_scheduler_template(scheduler_name, message: 'initial')
    end

    wait_for_recorded_command('--message=initial')

    write_config(queue_slots: 5, workers_pool_size: 3)
    write_scheduler_template(scheduler_name, message: 'updated')
    clear_recorded_commands

    assert Daemon.reload

    assert_equal 5, MediaLibrarian.application.queue_slots
    wait_for_recorded_command('--message=updated')
  end

  private

  def boot_daemon_environment(scheduler: nil)
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
    Client.configure(app: @environment.application)

    override_port

    yield if block_given?

    Librarian.new(container: @environment.container, args: [])

    @daemon_thread = Thread.new do
      Daemon.start(scheduler: scheduler, daemonize: false)
    end

    wait_for_http_ready
  end

  def override_port
    port = free_port
    @environment.application.api_option = { 'bind_address' => '127.0.0.1', 'listen_port' => port }
  end

  def recorded_commands
    @environment.application.args_dispatch.dispatched_commands
  end

  def clear_recorded_commands
    recorded_commands.clear
  end

  def wait_for_http_ready
    Timeout.timeout(10) do
      loop do
        response = Client.new.status
        break if response['status_code'] == 200

        sleep 0.05
      rescue Errno::ECONNREFUSED
        sleep 0.05
      end
    end
  end

  def wait_for_job(job_id)
    Timeout.timeout(10) do
      loop do
        response = Client.new.job_status(job_id)
        if response['status_code'] == 200 && response.dig('body', 'status') == 'finished'
          break
        end
        sleep 0.05
      end
    end
  end

  def wait_for_recorded_command(argument)
    Timeout.timeout(10) do
      loop do
        break if recorded_commands.any? { |entry| Array(entry[:command]).include?(argument) }

        sleep 0.05
      end
    end
  end

  def write_config(queue_slots:, workers_pool_size:)
    config = SimpleConfigMan::DEFAULT_SETTINGS.merge(
      'daemon' => {
        'workers_pool_size' => workers_pool_size,
        'queue_slots' => queue_slots
      }
    )
    File.write(@environment.application.config_file, config.to_yaml)
  end

  def write_scheduler_template(name, message:)
    template = {
      'periodic' => {
        'reload_task' => {
          'command' => 'Library.noop',
          'every' => '1 minutes',
          'args' => {
            'message' => message
          }
        }
      }
    }

    path = File.join(@environment.application.template_dir, "#{name}.yml")
    File.write(path, template.to_yaml)
  end

  def free_port
    TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }
  end
end

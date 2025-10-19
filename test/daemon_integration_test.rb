# frozen_string_literal: true

require 'socket'
require 'timeout'
require 'yaml'
require 'json'
require 'net/http'
require 'fileutils'
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

  def test_stop_endpoint_requires_control_token
    token = 'integration-secret'
    boot_daemon_environment(control_token: token)

    unauthorized = control_post('/stop')
    assert_equal 403, unauthorized[:status_code]

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

  def test_logs_endpoint_returns_tail
    boot_daemon_environment

    log_dir = File.join(@environment.application.config_dir, 'log')
    FileUtils.mkdir_p(log_dir)
    log_path = File.join(log_dir, 'medialibrarian.log')
    error_path = File.join(log_dir, 'medialibrarian_errors.log')

    lines = Array.new(50) { |index| "line#{index}" }.join("\n") + "\n"
    File.write(log_path, lines)
    File.write(error_path, "error_line\n")

    response = control_get('/logs')
    assert_equal 200, response[:status_code]

    logs = response[:body].fetch('logs')
    assert_match(/line49/, logs.fetch('medialibrarian.log'))
    assert_equal "error_line\n", logs.fetch('medialibrarian_errors.log')
  end

  def test_config_endpoint_allows_read_and_write_with_reload
    boot_daemon_environment

    initial = control_get('/config')
    assert_equal 200, initial[:status_code]
    assert_includes initial[:body].fetch('content'), 'queue_slots'

    new_config = {
      'daemon' => {
        'workers_pool_size' => 4,
        'queue_slots' => 7
      }
    }.to_yaml

    update = control_put('/config', body: { 'content' => new_config })
    assert_equal 204, update[:status_code]
    assert_equal new_config, File.read(@environment.application.config_file)

    reload = control_post('/config/reload')
    assert_equal 204, reload[:status_code]
    assert_equal 7, MediaLibrarian.application.queue_slots

    invalid = control_put('/config', body: { 'content' => "daemon: [" })
    assert_equal 422, invalid[:status_code]
    assert_equal new_config, File.read(@environment.application.config_file)
  end

  def test_scheduler_endpoint_updates_template_via_http
    scheduler_name = 'http_scheduler'

    boot_daemon_environment(scheduler: scheduler_name) do
      write_scheduler_template(scheduler_name, message: 'initial')
    end

    wait_for_recorded_command('--message=initial')

    new_template = scheduler_template_yaml(message: 'updated')
    response = control_put('/scheduler', body: { 'content' => new_template })
    assert_equal 204, response[:status_code]
    assert_equal new_template, File.read(File.join(@environment.application.template_dir, "#{scheduler_name}.yml"))

    clear_recorded_commands

    reload_response = control_post('/scheduler/reload')
    assert_equal 204, reload_response[:status_code]

    wait_for_recorded_command('--message=updated')

    fetched = control_get('/scheduler')
    assert_equal 200, fetched[:status_code]
    assert_equal new_template, fetched[:body].fetch('content')
  end

  def test_dashboard_interface_is_served_at_root
    boot_daemon_environment

    response = control_get_raw('/')
    assert_equal '200', response.code
    content_type = response['content-type'].to_s
    assert_includes content_type, 'text/html'
    assert_includes response.body, '<!DOCTYPE html>'
    assert_includes response.body, 'Media Librarian'
  end

  private

  def boot_daemon_environment(scheduler: nil, control_token: nil)
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
    Client.configure(app: @environment.application)

    override_port(control_token: control_token)

    yield if block_given?

    Librarian.new(container: @environment.container, args: [])

    @daemon_thread = Thread.new do
      Daemon.start(scheduler: scheduler, daemonize: false)
    end

    wait_for_http_ready
  end

  def override_port(control_token: nil)
    port = free_port
    options = { 'bind_address' => '127.0.0.1', 'listen_port' => port }
    options['control_token'] = control_token if control_token
    @environment.application.api_option = options
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

  def scheduler_template_yaml(message:)
    {
      'periodic' => {
        'reload_task' => {
          'command' => 'Library.noop',
          'every' => '1 minutes',
          'args' => {
            'message' => message
          }
        }
      }
    }.to_yaml
  end

  def free_port
    TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }
  end

  def control_get(path)
    perform_control_request(Net::HTTP::Get, path)
  end

  def control_put(path, body:)
    perform_control_request(Net::HTTP::Put, path, body: body)
  end

  def control_post(path, body: nil)
    perform_control_request(Net::HTTP::Post, path, body: body)
  end

  def control_get_raw(path)
    uri = control_uri(path)
    request = Net::HTTP::Get.new(uri)
    Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(request)
    end
  end

  def perform_control_request(klass, path, body: nil)
    uri = control_uri(path)
    request = klass.new(uri)
    if body
      request['Content-Type'] = 'application/json'
      request.body = JSON.dump(body)
    end

    Net::HTTP.start(uri.hostname, uri.port) do |http|
      response = http.request(request)
      parse_control_response(response)
    end
  end

  def parse_control_response(response)
    parsed = response.body.to_s.empty? ? nil : JSON.parse(response.body)
    { status_code: response.code.to_i, body: parsed }
  end

  def control_uri(path)
    URI::HTTP.build(
      host: @environment.application.api_option['bind_address'],
      port: @environment.application.api_option['listen_port'],
      path: path
    )
  end
end

# frozen_string_literal: true

require 'json'
require 'openssl'
require 'socket'
require 'httparty'

class Client
  include MediaLibrarian::AppContainerSupport

  def initialize(control_token: nil)
    options = app.api_option || {}
    @api_options = options
    @control_token = resolve_control_token(control_token, options)
  end

  def enqueue(command, wait: false, queue: nil, task: nil, internal: 0, capture_output: wait)
    response = perform(
      :post,
      '/jobs',
      body: JSON.dump(
        'command' => command,
        'wait' => false,
        'queue' => queue,
        'task' => task,
        'internal' => internal,
        'capture_output' => capture_output
      ),
      headers: json_headers
    )
    return response unless wait

    job_id = response.dig('body', 'job', 'id')
    return response unless job_id

    wait_for_job_completion(job_id)
  end

  def status
    perform(:get, '/status')
  end

  def job_status(job_id)
    perform(:get, "/jobs/#{job_id}")
  end

  def kill_job(job_id)
    perform(:delete, "/jobs/#{job_id}")
  end

  def stop
    perform(:post, '/stop')
  end

  private

  def perform(method, path, options = {})
    socket_error = nil

    if use_socket?
      response_line = socket_request(method, path, options)
      return parse_socket_response(response_line) if response_line

      socket_error = @last_socket_error
    end

    return perform_http(method, path, options) if http_configured?

    { 'status_code' => 503, 'error' => connection_error_message(socket_error) }
  end

  attr_reader :control_token, :api_options

  def resolve_control_token(explicit_token, options)
    candidates = [
      explicit_token,
      options['api_token'], options[:api_token],
      options['control_token'], options[:control_token],
      ENV['MEDIA_LIBRARIAN_API_TOKEN'], ENV['MEDIA_LIBRARIAN_CONTROL_TOKEN']
    ]
    candidates.find { |c| c.is_a?(String) ? !c.strip.empty? : c }&.then { |v| v.is_a?(String) ? v.strip : v }
  end

  def socket_path
    api_options['socket_path'] || Daemon::SOCKET_PATH
  end

  def use_socket?
    path = socket_path
    return false if path.to_s.empty?

    File.socket?(path)
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def socket_request(method, path, options)
    payload = {
      'method' => method.to_s.upcase,
      'path' => path,
      'headers' => default_headers.merge(options.fetch(:headers, {})),
      'body' => options[:body]
    }
    response_line = nil

    UNIXSocket.open(socket_path) do |socket|
      socket.write(JSON.dump(payload) + "\n")
      response_line = socket.gets
    end

    response_line
  rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::ECONNRESET, IOError => e
    @last_socket_error = e
    nil
  end

  def perform_http(method, path, options)
    response = HTTParty.send(method, path, httparty_options(options))
    parse_http_response(response)
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
    { 'status_code' => 503, 'error' => connection_error_message(e) }
  end

  def ssl_enabled?
    truthy?(api_options['ssl_enabled'])
  end

  def resolve_ssl_verify_mode(mode)
    return mode if mode.is_a?(Integer)

    case mode.to_s.downcase
    when '', 'none', 'off', 'false'
      OpenSSL::SSL::VERIFY_NONE
    when 'peer'
      OpenSSL::SSL::VERIFY_PEER
    when 'fail_if_no_peer_cert', 'force_peer', 'require'
      OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
    else
      OpenSSL::SSL::VERIFY_NONE
    end
  end

  def truthy?(value)
    case value
    when true then true
    when false, nil then false
    when String then value.match?(/\A(true|1|yes|on)\z/i)
    when Numeric then !value.zero?
    else
      !!value
    end
  end

  def http_configured?
    !api_options['bind_address'].to_s.empty? && !api_options['listen_port'].to_s.empty?
  end

  def base_uri
    "#{ssl_enabled? ? 'https' : 'http'}://#{api_options['bind_address']}:#{api_options['listen_port']}"
  end

  def httparty_options(extra = {})
    headers = default_headers.merge(extra.fetch(:headers, {}))
    ssl_options = httparty_ssl_options

    { base_uri: base_uri, headers: headers, timeout: 120 }
      .merge(ssl_options)
      .merge(extra.reject { |key, _| key == :headers })
  end

  def default_headers
    return {} unless control_token
    { 'X-Control-Token' => control_token }
  end

  def json_headers
    default_headers.merge('Content-Type' => 'application/json')
  end

  def httparty_ssl_options
    return {} unless ssl_enabled?

    options = {}
    verify_mode = resolve_ssl_verify_mode(api_options['ssl_verify_mode'])
    options[:verify] = verify_mode != OpenSSL::SSL::VERIFY_NONE unless verify_mode.nil?
    options[:ssl_verify_mode] = verify_mode unless verify_mode.nil?

    ca_path = api_options['ssl_ca_path']
    if ca_path && !ca_path.to_s.empty?
      options[:ssl_ca_path] = ca_path if File.directory?(ca_path)
      options[:ssl_ca_file] = ca_path if File.file?(ca_path)
    end

    options
  end

  def parse_http_response(response)
    body = response.body.to_s.empty? ? nil : JSON.parse(response.body)
    { 'status_code' => response.code.to_i, 'body' => body }
  end

  def wait_for_job_completion(job_id)
    output_cursor = 0
    loop do
      response = job_status(job_id)
      return response unless response['status_code'] == 200

      job = response['body']
      output = job.is_a?(Hash) ? job['output'].to_s : ''
      if output.length > output_cursor
        $stdout.write(output[output_cursor..])
        $stdout.flush
        output_cursor = output.length
      end

      status = job.is_a?(Hash) ? job['status'] : nil
      if Daemon::FINISHED_STATUSES.include?(status)
        return { 'status_code' => 200, 'body' => { 'job' => job } }
      end

      sleep 0.05
    end
  end

  def parse_socket_response(response_line)
    raise JSON::ParserError if response_line.to_s.strip.empty?

    parsed = JSON.parse(response_line)
    return parsed if parsed.is_a?(Hash)

    { 'status_code' => 502, 'error' => 'Invalid daemon response' }
  rescue JSON::ParserError
    { 'status_code' => 502, 'error' => 'Invalid daemon response' }
  end

  def connection_error_message(error)
    case error
    when Errno::ECONNREFUSED
      'Failed to connect to daemon'
    when Net::OpenTimeout, Net::ReadTimeout
      'Timed out waiting for daemon response'
    when Errno::ENOENT
      'Daemon socket missing'
    else
      error.message
    end
  end
end

# frozen_string_literal: true

require 'json'
require 'openssl'
require 'httparty'

class Client
  include MediaLibrarian::AppContainerSupport

  def initialize(control_token: nil)
    options = app.api_option || {}
    @api_options = options
    @control_token = resolve_control_token(control_token, options)
  end

  def enqueue(command, wait: true, queue: nil, task: nil, internal: 0, capture_output: wait)
    perform(
      :post,
      '/jobs',
      body: JSON.dump(
        'command' => command,
        'wait' => wait,
        'queue' => queue,
        'task' => task,
        'internal' => internal,
        'capture_output' => capture_output
      ),
      headers: json_headers
    )
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
    response = HTTParty.send(method, path, httparty_options(options))
    parse_response(response)
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
    { 'status_code' => 503, 'error' => connection_error_message(e) }
  end

  def parse_response(response)
    body = response.body.to_s.empty? ? nil : JSON.parse(response.body)
    { 'status_code' => response.code.to_i, 'body' => body }
  end

  attr_reader :control_token

  def resolve_control_token(explicit_token, options)
    select_token(
      explicit_token,
      options['api_token'],
      options[:api_token],
      options['control_token'],
      options[:control_token],
      ENV['MEDIA_LIBRARIAN_API_TOKEN'],
      ENV['MEDIA_LIBRARIAN_CONTROL_TOKEN']
    )
  end

  def select_token(*candidates)
    candidates.each do |candidate|
      value = normalize_token(candidate)
      return value if value
    end
    nil
  end

  def normalize_token(candidate)
    case candidate
    when nil
      nil
    when String
      token = candidate.strip
      token.empty? ? nil : token
    else
      candidate
    end
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

  attr_reader :api_options

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

  def connection_error_message(error)
    case error
    when Errno::ECONNREFUSED
      'Failed to connect to daemon'
    when Net::OpenTimeout, Net::ReadTimeout
      'Timed out waiting for daemon response'
    else
      error.message
    end
  end
end

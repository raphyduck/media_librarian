# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'openssl'

class Client
  include MediaLibrarian::AppContainerSupport

  def initialize(control_token: nil)
    options = app.api_option || {}
    @api_options = options
    @control_token = resolve_control_token(control_token, options)
  end

  def enqueue(command, wait: true, queue: nil, task: nil, internal: 0, capture_output: wait)
    request = Net::HTTP::Post.new(uri_for('/jobs'))
    request['Content-Type'] = 'application/json'
    payload = {
      'command' => command,
      'wait' => wait,
      'queue' => queue,
      'task' => task,
      'internal' => internal,
      'capture_output' => capture_output
    }
    payload['token'] = control_token if control_token
    request.body = JSON.dump(payload)
    perform(request)
  end

  def status
    perform(Net::HTTP::Get.new(uri_for('/status', include_token: true)))
  end

  def job_status(job_id)
    perform(Net::HTTP::Get.new(uri_for("/jobs/#{job_id}", include_token: true)))
  end

  def stop
    request = Net::HTTP::Post.new(uri_for('/stop'))
    if control_token
      request['Content-Type'] = 'application/json'
      request.body = JSON.dump('token' => control_token)
    end
    perform(request)
  end

  private

  def perform(request)
    attach_client_headers(request)

    http_options = net_http_options
    Net::HTTP.start(request.uri.hostname, request.uri.port, **http_options) do |http|
      http.read_timeout = 120
      response = http.request(request)
      parse_response(response)
    end
  rescue Errno::ECONNREFUSED, OpenSSL::SSL::SSLError => e
    { 'status_code' => 503, 'error' => e.message }
  end

  def parse_response(response)
    body = response.body.to_s.empty? ? nil : JSON.parse(response.body)
    { 'status_code' => response.code.to_i, 'body' => body }
  end

  def uri_for(path, include_token: false)
    builder = ssl_enabled? ? URI::HTTPS : URI::HTTP
    query = include_token && control_token ? URI.encode_www_form('token' => control_token) : nil
    builder.build(
      host: app.api_option['bind_address'],
      port: app.api_option['listen_port'],
      path: path,
      query: query
    )
  end

  attr_reader :control_token

  def attach_client_headers(request)
    request['X-Requested-By'] ||= 'librarian-cli'
    return unless control_token

    request['X-Control-Token'] = control_token
  end

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

  def net_http_options
    return {} unless ssl_enabled?

    options = { use_ssl: true }
    verify_mode = resolve_ssl_verify_mode(api_options['ssl_verify_mode'])
    options[:verify_mode] = verify_mode unless verify_mode.nil?

    ca_path = api_options['ssl_ca_path']
    if ca_path && !ca_path.to_s.empty?
      case ca_path
      when ->(path) { File.directory?(path) }
        options[:ca_path] = ca_path
      when ->(path) { File.file?(path) }
        options[:ca_file] = ca_path
      end
    end

    options
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
end

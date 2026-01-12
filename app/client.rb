# frozen_string_literal: true

require 'json'
require 'socket'

class Client
  include MediaLibrarian::AppContainerSupport

  SOCKET_PATH = '/home/raph/.medialibrarian/librarian.sock'

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

    parse_response(response_line)
  rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::ECONNRESET, IOError => e
    { 'status_code' => 503, 'error' => connection_error_message(e) }
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

  attr_reader :api_options

  def socket_path
    api_options['socket_path'] || SOCKET_PATH
  end

  def default_headers
    return {} unless control_token
    { 'X-Control-Token' => control_token }
  end

  def json_headers
    default_headers.merge('Content-Type' => 'application/json')
  end

  def parse_response(response_line)
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
    when Errno::ENOENT
      'Daemon socket missing'
    else
      error.message
    end
  end
end

# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

class Client
  include MediaLibrarian::AppContainerSupport

  def enqueue(command, wait: true, queue: nil, task: nil, internal: 0)
    request = Net::HTTP::Post.new(uri_for('/jobs'))
    request['Content-Type'] = 'application/json'
    request.body = JSON.dump(
      'command' => command,
      'wait' => wait,
      'queue' => queue,
      'task' => task,
      'internal' => internal
    )
    perform(request)
  end

  def status
    perform(Net::HTTP::Get.new(uri_for('/status')))
  end

  def job_status(job_id)
    perform(Net::HTTP::Get.new(uri_for("/jobs/#{job_id}")))
  end

  def stop
    perform(Net::HTTP::Post.new(uri_for('/stop')))
  end

  private

  def perform(request)
    Net::HTTP.start(request.uri.hostname, request.uri.port) do |http|
      http.read_timeout = 120
      response = http.request(request)
      parse_response(response)
    end
  rescue Errno::ECONNREFUSED => e
    { 'status_code' => 503, 'error' => e.message }
  end

  def parse_response(response)
    body = response.body.to_s.empty? ? nil : JSON.parse(response.body)
    { 'status_code' => response.code.to_i, 'body' => body }
  end

  def uri_for(path)
    URI::HTTP.build(
      host: app.api_option['bind_address'],
      port: app.api_option['listen_port'],
      path: path
    )
  end
end

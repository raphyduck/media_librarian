# frozen_string_literal: true

require_relative 'env'

class HttpDebugLogger
  MAX_BODY = 250

  def self.log(provider:, method:, url:, payload: nil, response: nil, speaker: nil)
    return unless Env.debug?

    speaker ||= MediaLibrarian.app.speaker if defined?(MediaLibrarian)
    payload_text = payload.nil? ? 'nil' : payload.inspect
    speaker&.speak_up("#{provider} #{method} #{url} payload=#{payload_text} response=#{response_summary(response)}", 0)
  end

  def self.log_request(provider:, response:, method: nil, url: nil, payload: nil, speaker: nil)
    request_method, request_url, request_payload = extract_request_details(response)
    log(
      provider: provider,
      method: (request_method || method || 'unknown').to_s.upcase,
      url: (request_url || url || 'unknown').to_s,
      payload: request_payload.nil? ? payload : request_payload,
      response: response,
      speaker: speaker
    )
  end

  def self.response_summary(response)
    status = if response.respond_to?(:code)
               response.code
             elsif response.is_a?(Hash)
               response[:status] || response['status']
             end
    body = response.respond_to?(:body) ? response.body : response
    "status #{status || 'unknown'} body #{truncate_body(body)}"
  end

  def self.truncate_body(body)
    text = body.to_s.strip
    return text if text.length <= MAX_BODY

    "#{text[0, MAX_BODY]}..."
  end

  def self.extract_request_details(response)
    request = response.respond_to?(:request) ? response.request : nil
    if request
      method = request.respond_to?(:http_method) ? request.http_method : request_method_fallback(request)
      url = request.respond_to?(:uri) ? request.uri : request.respond_to?(:url) ? request.url : nil
      payload = if request.respond_to?(:body)
                  request.body
                elsif request.respond_to?(:options)
                  options = request.options
                  options[:body] || options[:query] || options[:payload]
                end
      return [method, url, payload]
    end

    return [nil, nil, nil] unless response.respond_to?(:env)

    env = response.env
    method = env[:method] || env['method']
    url = env[:url] || env['url']
    payload = env[:body] || env['body'] || env[:request_body]
    [method, url, payload]
  end

  def self.request_method_fallback(request)
    return request.verb if request.respond_to?(:verb)
    return request.method if request.respond_to?(:method)

    nil
  end
end

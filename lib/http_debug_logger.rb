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
end

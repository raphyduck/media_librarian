require 'themoviedb'
require_relative '../boot/librarian'
require_relative '../lib/http_debug_logger'

app = MediaLibrarian::Boot.application
Tmdb::Api.key(app.config['tmdb']['api_key']) if app.config['tmdb'] && app.config['tmdb']['api_key']

if defined?(Tmdb::Api)
  class << Tmdb::Api
    unless instance_variable_defined?(:@http_debug_wrapped)
      @http_debug_wrapped = true
      alias_method :http_debug_original_get, :get

      def get(path, options = {}, &block)
        url = HttpDebugLogger.build_url(base_uri, path)
        payload = options[:body] || options[:query] || options[:payload]
        HttpDebugLogger.log(provider: 'TMDb', method: :get, url: url, payload: payload)

        response = http_debug_original_get(path, options, &block)
        HttpDebugLogger.log_request(provider: 'TMDb', response: response, method: :get, url: url, payload: payload)
        response
      rescue StandardError => e
        HttpDebugLogger.log(
          provider: 'TMDb',
          method: :get,
          url: url,
          payload: payload,
          response: "exception #{e.class}: #{e.message}"
        )
        raise
      end
    end
  end
end

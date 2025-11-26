require 'json'
require 'net/http'
require 'openssl'

class TraktAgent
  def self.calendars__all_movies(start_date, days)
    fetch_calendar_entries(:movies, start_date, days)
  end

  def self.calendars__all_shows(start_date, days)
    fetch_calendar_entries(:shows, start_date, days)
  end

  def self.method_missing(name, *args)
    segments = name.to_s.split('__')
    return unless segments[0] && segments[1]

    MediaLibrarian.app.speaker.speak_up(
      "Running TraktAgent.#{segments[0]}__#{segments[1]}(#{DataUtils.format_string(args).join(', ')})",
      0
    ) if Env.debug?

    target = MediaLibrarian.app.trakt.public_send(segments[0])
    target.public_send(segments[1], *args)
  rescue StandardError => e
    MediaLibrarian.app.speaker.tell_error(e, "TraktAgent.#{name}")
  end

  def self.fetch_calendar_entries(type, start_date, days)
    calendars_client = MediaLibrarian.app.trakt
    if calendars_client&.respond_to?(:calendars)
      calendars = calendars_client.calendars
      all_method = "all_#{type}".to_sym
      return calendars.public_send(all_method, start_date, days) if calendars.respond_to?(all_method)
      return calendars.public_send(type, start_date, days) if calendars.respond_to?(type)
    end

    if calendars_client&.respond_to?(:calendar)
      return calendars_client.calendar(type: type.to_s.delete_suffix('s'), start_date: start_date, days: days) rescue nil
    end

    fetch_calendar_from_http(type, start_date, days)
  rescue StandardError => e
    MediaLibrarian.app.speaker.tell_error(e, "TraktAgent.calendars__#{type}")
    nil
  end

  def self.fetch_calendar_from_http(type, start_date, days)
    config = MediaLibrarian.app.config['trakt'] || {}
    client_id = config['client_id'].to_s
    access_token = config['access_token'].to_s
    return nil if client_id.empty?

    uri = URI("https://api.trakt.tv/calendars/all/#{type}/#{start_date.strftime('%Y-%m-%d')}/#{days}")
    request = Net::HTTP::Get.new(uri)
    request['Content-Type'] = 'application/json'
    request['trakt-api-version'] = '2'
    request['trakt-api-key'] = client_id
    request['Authorization'] = "Bearer #{access_token}" unless access_token.empty?

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, ssl_context: build_ssl_context(config)) do |http|
      http.request(request)
    end

    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue StandardError => e
    MediaLibrarian.app.speaker.tell_error(e, "TraktAgent.calendar_http_#{type}")
    nil
  end

  def self.build_ssl_context(config)
    context = OpenSSL::SSL::SSLContext.new
    context.verify_mode = OpenSSL::SSL::VERIFY_PEER
    context.cert_store = build_cert_store(config)
    context
  end

  def self.build_cert_store(config)
    store = OpenSSL::X509::Store.new
    ca_path = config['ca_path'].to_s
    ca_path.empty? ? store.set_default_paths : store.add_path(ca_path)
    store.flags = OpenSSL::X509::V_FLAG_CRL_CHECK_ALL unless config['disable_crl_checks']
    store
  end
end

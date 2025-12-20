require_relative 'http_debug_logger'

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

    target = MediaLibrarian.app.trakt.public_send(segments[0])
    response = target.public_send(segments[1], *args)

    log_trakt_request(target, response, args)

    response
  rescue StandardError => e
    segments = name.to_s.split('__', 2)
    args_formatted = DataUtils.format_string(args).join(', ')
    info = []
    info << "target=#{segments[0]}" if segments[0]
    info << "method=#{segments[1]}" if segments[1]
    info << "args=#{args_formatted}" unless args_formatted.empty?
    suffix = info.empty? ? '' : " #{info.join(' ')}"
    MediaLibrarian.app.speaker.tell_error(e, "TraktAgent.#{name}#{suffix}")
  end

  def self.fetch_calendar_entries(type, start_date, days, fetcher: nil)
    calendar = calendar_client(fetcher || MediaLibrarian.app.trakt)
    return unless calendar

    response = call_calendar(calendar, type, start_date, days)
    log_trakt_request(calendar, response, { type: type, start_date: start_date, days: days })
    response
  rescue StandardError => e
    MediaLibrarian.app.speaker.tell_error(e, "TraktAgent.calendars__#{type}")
    nil
  end

  def self.calendar_client(fetcher)
    return fetcher.calendar if fetcher&.respond_to?(:calendar)
    return fetcher.calendars if fetcher&.respond_to?(:calendars)
  end

  def self.call_calendar(calendar, type, start_date, days)
    %I[all_#{type} #{type}].each do |method|
      return calendar.public_send(method, start_date, days) if calendar.respond_to?(method)
    end
  end

  def self.log_trakt_request(target, response, payload)
    response_obj = if target.respond_to?(:last_response)
                     target.last_response
                   else
                     response
                   end
    url = trakt_request_url(target, response_obj)
    HttpDebugLogger.log(
      provider: 'Trakt',
      method: 'GET',
      url: url || 'unknown',
      payload: payload,
      response: response_obj,
      speaker: MediaLibrarian.app.speaker
    )
  end

  def self.trakt_request_url(target, response)
    if response.respond_to?(:request) && response.request.respond_to?(:uri)
      return response.request.uri.to_s
    end
    return target.last_request_path if target.respond_to?(:last_request_path)
    return target.endpoint if target.respond_to?(:endpoint)
    return target.url if target.respond_to?(:url)

    if target.respond_to?(:base_url) && target.respond_to?(:path)
      return "#{target.base_url}#{target.path}"
    end
    target.base_url if target.respond_to?(:base_url)
  end
end

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

    args_formatted = DataUtils.format_string(args).join(', ')
    target = MediaLibrarian.app.trakt.public_send(segments[0])
    response = target.public_send(segments[1], *args)

    if Env.debug?
      response_summary = case response
                         when nil then 'nil'
                         when Array then "Array(size=#{response.size})"
                         when Hash then "Hash(keys=#{response.keys.size})"
                         else response.class.to_s
                         end
      MediaLibrarian.app.speaker.speak_up(
        "TraktAgent.#{segments[0]}__#{segments[1]} target=#{target.class} args=#{args_formatted} => #{response_summary}",
        0
      )
    end

    response
  rescue StandardError => e
    MediaLibrarian.app.speaker.tell_error(e, "TraktAgent.#{name}")
  end

  def self.fetch_calendar_entries(type, start_date, days, fetcher: nil)
    calendar = calendar_client(fetcher || MediaLibrarian.app.trakt)
    return unless calendar

    call_calendar(calendar, type, start_date, days)
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
end

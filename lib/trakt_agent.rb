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
    response = target.public_send(segments[1], *args)

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

end

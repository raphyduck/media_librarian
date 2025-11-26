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

  def self.fetch_calendar_entries(type, start_date, days, fetcher: nil)
    calendars_client = fetcher || MediaLibrarian.app.trakt
    calendars = calendars_client&.respond_to?(:calendars) ? calendars_client.calendars : calendars_client

    if calendars
      all_method = "all_#{type}".to_sym
      return calendars.public_send(all_method, start_date, days) if calendars.respond_to?(all_method)
      return calendars.public_send(type, start_date, days) if calendars.respond_to?(type)
    end

    return calendars_client.calendar(type: type.to_s.delete_suffix('s'), start_date: start_date, days: days) if calendars_client&.respond_to?(:calendar)
  rescue StandardError => e
    MediaLibrarian.app.speaker.tell_error(e, "TraktAgent.calendars__#{type}")
    nil
  end
end

class TraktAgent
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
end

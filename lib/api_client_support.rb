# frozen_string_literal: true

# Shared plumbing for the small external API clients (OMDb, MusicBrainz,
# AcoustID): debug logging and error reporting through the injected @speaker,
# plus common value helpers. Keeps each client focused on its own protocol.
module ApiClientSupport
  private

  def log_debug(message)
    return unless defined?(Env) && Env.debug?

    @speaker&.speak_up(message)
  rescue StandardError
    nil
  end

  def report_error(error, message)
    @speaker&.tell_error(error, message)
  rescue StandardError
    nil
  end

  def present(value)
    !value.to_s.strip.empty?
  end

  def compact_tags(tags)
    tags.reject { |_, value| value.to_s.strip.empty? }
  end
end

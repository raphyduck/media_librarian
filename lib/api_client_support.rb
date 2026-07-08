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

  # Transient HTTP failures (timeouts, resets, 5xx and 429 rate-limits) are the
  # norm when hammering MusicBrainz/iTunes across thousands of files. Retry a few
  # times with exponential backoff + jitter so one blip does not leave a file
  # untagged. A 429 with Retry-After is honoured. Non-retryable errors re-raise
  # immediately; after the last attempt the original error propagates so the
  # caller's rescue still logs it and the staging-guard keeps the file.
  RETRYABLE_ERRORS = [
    defined?(Net::OpenTimeout) ? Net::OpenTimeout : nil,
    defined?(Net::ReadTimeout) ? Net::ReadTimeout : nil,
    defined?(Errno::ECONNRESET) ? Errno::ECONNRESET : nil,
    defined?(Errno::ECONNREFUSED) ? Errno::ECONNREFUSED : nil,
    defined?(OpenSSL::SSL::SSLError) ? OpenSSL::SSL::SSLError : nil,
    (defined?(HTTParty::Error) ? HTTParty::Error : nil),
    SocketError, IOError, Timeout::Error
  ].compact.freeze

  class RateLimitedError < StandardError
    attr_reader :retry_after
    def initialize(message = 'rate limited', retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end

  def with_retries(max_attempts: 4, base_delay: 1.0, max_delay: 30.0)
    attempt = 0
    begin
      attempt += 1
      yield
    rescue RateLimitedError => e
      raise if attempt >= max_attempts
      wait = e.retry_after || backoff_delay(attempt, base_delay, max_delay)
      log_debug("retry #{attempt}/#{max_attempts} after rate limit, sleeping #{wait}s")
      sleep(wait)
      retry
    rescue *RETRYABLE_ERRORS => e
      raise if attempt >= max_attempts
      wait = backoff_delay(attempt, base_delay, max_delay)
      log_debug("retry #{attempt}/#{max_attempts} after #{e.class}: sleeping #{wait}s")
      sleep(wait)
      retry
    end
  end

  def backoff_delay(attempt, base_delay, max_delay)
    delay = base_delay * (2**(attempt - 1))
    delay = max_delay if delay > max_delay
    delay + rand * (delay * 0.25) # jitter up to +25%
  end

  def present(value)
    !value.to_s.strip.empty?
  end

  def compact_tags(tags)
    tags.reject { |_, value| value.to_s.strip.empty? }
  end
end

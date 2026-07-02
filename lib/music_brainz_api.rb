# frozen_string_literal: true

require 'json'
require 'uri'
require 'httparty'

# Minimal MusicBrainz client used to complete missing music tags (artist,
# album, title, year) when a downloaded file has incomplete metadata.
#
# MusicBrainz asks clients to send a descriptive User-Agent and to stay under
# one request per second; both are enforced here. Lookups are memoized per
# instance and failures degrade gracefully to an empty result.
class MusicBrainzApi
  BASE_URL = 'https://musicbrainz.org/ws/2'
  MIN_INTERVAL = 1.1
  DEFAULT_TIMEOUT = 15
  SEARCH_LIMIT = 5

  @mutex = Mutex.new
  @last_request_at = nil

  class << self
    attr_accessor :last_request_at
    attr_reader :mutex
  end

  def initialize(contact: nil, http_client: HTTParty, speaker: nil, timeout: nil, user_agent: nil, cache: nil)
    @http_client = http_client
    @speaker = speaker
    @timeout = timeout || DEFAULT_TIMEOUT
    contact = contact.to_s.strip
    contact = 'https://github.com/raphyduck/media_librarian' if contact.empty?
    @user_agent = user_agent || "media_librarian/1.0 ( #{contact} )"
    @cache = cache
    @memo = {}
  end

  # Returns a hash with any of :artist, :album, :title, :year that could be
  # resolved (empty hash when nothing is found).
  def complete(artist: '', album: '', title: '', track: '')
    if present(title)
      normalize_recording(search('recording', recording_query(artist, title)))
    elsif present(album)
      normalize_release(search('release', release_query(artist, album)), track)
    else
      {}
    end
  rescue StandardError => e
    report_error(e, 'MusicBrainz lookup failed')
    {}
  end

  # --- Pure parsers (unit-tested) -------------------------------------------

  def normalize_recording(payload)
    recording = Array(payload && payload['recordings']).first
    return {} unless recording.is_a?(Hash)

    releases = Array(recording['releases'])
    compact_tags(
      :artist => artist_credit_name(recording['artist-credit']),
      :title => recording['title'].to_s,
      :album => releases.first.is_a?(Hash) ? releases.first['title'].to_s : '',
      :year => year_from(releases.map { |release| release.is_a?(Hash) ? release['date'] : nil })
    )
  end

  def normalize_release(payload, track = '')
    release = Array(payload && payload['releases']).first
    return {} unless release.is_a?(Hash)

    tags = compact_tags(
      :artist => artist_credit_name(release['artist-credit']),
      :album => release['title'].to_s,
      :year => year_from([release['date']])
    )
    if present(track) && present(release['id'])
      title = release_track_title(release['id'], track)
      tags[:title] = title if present(title)
    end
    tags
  end

  def artist_credit_name(artist_credit)
    Array(artist_credit).map do |credit|
      next '' unless credit.is_a?(Hash)

      name = credit['name']
      name = credit.dig('artist', 'name') if name.to_s.empty?
      "#{name}#{credit['joinphrase']}"
    end.join.strip
  end

  private

  def recording_query(artist, title)
    query = %(recording:"#{escape(title)}")
    query += %( AND artist:"#{escape(artist)}") if present(artist)
    query
  end

  def release_query(artist, album)
    query = %(release:"#{escape(album)}")
    query += %( AND artist:"#{escape(artist)}") if present(artist)
    query
  end

  def release_track_title(release_id, track)
    payload = get_json("/release/#{release_id}", { inc: 'recordings', fmt: 'json' })
    position = track.to_s[/\d+/].to_i
    return '' if position <= 0

    Array(payload && payload['media']).each do |medium|
      next unless medium.is_a?(Hash)

      track_entry = Array(medium['tracks']).find { |entry| entry.is_a?(Hash) && entry['position'].to_i == position }
      return track_entry['title'].to_s if track_entry
    end
    ''
  end

  def search(entity, query)
    get_json("/#{entity}", { query: query, fmt: 'json', limit: SEARCH_LIMIT })
  end

  def get_json(path, query)
    cache_key = "mb:#{path}?#{query.sort_by { |k, _| k.to_s }.map { |k, v| "#{k}=#{v}" }.join('&')}"
    return @memo[cache_key] if @memo.key?(cache_key)

    # Only successful responses are persisted; transient errors raise out of the
    # block so JsonDiskCache does not cache them.
    value = begin
      if @cache
        @cache.fetch(cache_key) { fetch_remote(path, query) }
      else
        fetch_remote(path, query)
      end
    rescue StandardError => e
      report_error(e, 'MusicBrainz request failed')
      nil
    end
    @memo[cache_key] = value
    value
  end

  def fetch_remote(path, query)
    throttle
    url = "#{BASE_URL}#{path}"
    log_debug("MusicBrainz request: #{url} #{query.inspect}")
    response = @http_client.get(url, query: query, timeout: @timeout, headers: { 'User-Agent' => @user_agent })
    status = response.respond_to?(:code) ? response.code.to_i : nil
    raise StandardError, "MusicBrainz request failed with status #{status || 'unknown'}" unless status && status.between?(200, 299)

    JSON.parse(response.body.to_s)
  end

  # Enforce the one-request-per-second MusicBrainz rate limit across instances.
  def throttle
    self.class.mutex.synchronize do
      last = self.class.last_request_at
      if last
        wait = MIN_INTERVAL - (Time.now - last)
        sleep(wait) if wait.positive?
      end
      self.class.last_request_at = Time.now
    end
  end

  def compact_tags(tags)
    tags.reject { |_, value| value.to_s.strip.empty? }
  end

  def year_from(dates)
    Array(dates).map { |date| date.to_s[/\d{4}/] }.compact.first.to_s
  end

  def escape(value)
    value.to_s.gsub(/["\\]/, ' ').gsub(/\s+/, ' ').strip
  end

  def present(value)
    !value.to_s.strip.empty?
  end

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
end

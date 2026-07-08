# frozen_string_literal: true

# Secondary metadata provider used when MusicBrainz is unavailable or returns
# nothing (e.g. rate-limited / IP-blocked). The iTunes Search API needs no API
# key; official guidance is ~20 requests/minute, enforced here with a 3s
# throttle shared across instances. Interface mirrors MusicBrainzApi#complete.
class ItunesSearchApi
  BASE_URL = 'https://itunes.apple.com/search'
  DEFAULT_TIMEOUT = 10
  SEARCH_LIMIT = 5
  THROTTLE_SECONDS = 3

  @mutex = Mutex.new
  @last_request_at = nil

  class << self
    attr_accessor :last_request_at
    attr_reader :mutex
  end

  def initialize(http_client: HTTParty, speaker: nil, timeout: nil, cache: nil)
    @http_client = http_client
    @speaker = speaker
    @timeout = timeout || DEFAULT_TIMEOUT
    @cache = cache
    @memo = {}
  end

  # Returns a hash with any of :artist, :album, :title, :year that could be
  # resolved (empty hash when nothing is found). Existing-tag precedence is
  # handled by the caller (merge_tags).
  def complete(artist: '', album: '', title: '', track: '')
    if present(title)
      normalize_song(search(term_for(artist, title), 'song'))
    elsif present(album)
      normalize_album(search(term_for(artist, album), 'album'))
    else
      {}
    end
  rescue StandardError => e
    report_error(e, 'iTunes lookup failed')
    {}
  end

  # --- Pure parsers (unit-tested) -------------------------------------------

  def normalize_song(payload)
    result = Array(payload && payload['results']).first
    return {} unless result.is_a?(Hash)

    compact_tags(
      :artist => result['artistName'].to_s,
      :album => result['collectionName'].to_s,
      :title => result['trackName'].to_s,
      :track => result['trackNumber'].to_s,
      :disc => result['discNumber'].to_s,
      :year => year_from(result['releaseDate'])
    )
  end

  def normalize_album(payload)
    result = Array(payload && payload['results']).first
    return {} unless result.is_a?(Hash)

    compact_tags(
      :artist => result['artistName'].to_s,
      :album => result['collectionName'].to_s,
      :year => year_from(result['releaseDate'])
    )
  end

  private

  def term_for(artist, main)
    [artist, main].map(&:to_s).reject(&:empty?).join(' ').strip
  end

  def search(term, entity)
    get_json(term: term, media: 'music', entity: entity, limit: SEARCH_LIMIT)
  end

  def get_json(query)
    cache_key = "itunes:#{query.sort_by { |k, _| k.to_s }.map { |k, v| "#{k}=#{v}" }.join('&')}"
    return @memo[cache_key] if @memo.key?(cache_key)

    value = begin
      if @cache
        @cache.fetch(cache_key) { fetch_remote(query) }
      else
        fetch_remote(query)
      end
    rescue StandardError => e
      report_error(e, 'iTunes request failed')
      nil
    end
    @memo[cache_key] = value
    value
  end

  def fetch_remote(query)
    throttle
    response = @http_client.get(BASE_URL, query: query, timeout: @timeout,
                                          headers: { 'Accept' => 'application/json' })
    raise "iTunes HTTP #{response.code}" unless response.code.to_i == 200

    payload = response.parsed_response
    payload = JSON.parse(payload) if payload.is_a?(String)
    payload
  end

  def throttle
    self.class.mutex.synchronize do
      last = self.class.last_request_at
      wait = last ? THROTTLE_SECONDS - (Time.now - last) : 0
      sleep(wait) if wait.positive?
      self.class.last_request_at = Time.now
    end
  end

  def year_from(date)
    match = date.to_s[/\d{4}/]
    match.to_s
  end

  def compact_tags(hash)
    hash.reject { |_, value| value.to_s.strip.empty? }
  end

  def present(value)
    !value.to_s.strip.empty?
  end

  def report_error(error, message)
    @speaker&.tell_error(error, message)
  rescue StandardError
    nil
  end
end

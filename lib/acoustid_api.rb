# frozen_string_literal: true

require 'json'
require 'open3'
require 'digest'
require 'httparty'
require_relative 'api_client_support'

# Identify an audio track from its acoustic fingerprint via AcoustID.
#
# The fingerprint is computed with Chromaprint's `fpcalc` binary (system
# dependency), then submitted to the AcoustID web service, which returns
# MusicBrainz-backed metadata. This is the most reliable identifier when a file
# has no usable tags or file name. Requires a free AcoustID application API key.
class AcoustidApi
  include ApiClientSupport

  BASE_URL = 'https://api.acoustid.org/v2/lookup'
  DEFAULT_TIMEOUT = 20
  FINGERPRINT_LENGTH = 120
  MIN_SCORE = 0.5

  def initialize(api_key:, http_client: HTTParty, speaker: nil, timeout: nil, cache: nil, fpcalc: 'fpcalc')
    @api_key = api_key.to_s.strip
    @http_client = http_client
    @speaker = speaker
    @timeout = timeout || DEFAULT_TIMEOUT
    @cache = cache
    @fpcalc = fpcalc
    @memo = {}
  end

  def enabled?
    !@api_key.empty?
  end

  # Identify +path+; returns a tags hash (:artist, :title, :album, :year) or {}.
  def lookup(path)
    return {} unless enabled?

    fp = fingerprint(path)
    return {} if fp.nil?

    payload = query(fp[:fingerprint], fp[:duration])
    normalize_response(payload)
  rescue StandardError => e
    report_error(e, 'AcoustID lookup failed')
    {}
  end

  # Run fpcalc and return { duration:, fingerprint: } (or nil when unavailable).
  def fingerprint(path)
    stdout, status = Open3.capture2(@fpcalc, '-json', '-length', FINGERPRINT_LENGTH.to_s, path.to_s)
    return nil unless status.success?

    data = JSON.parse(stdout)
    fingerprint = data['fingerprint'].to_s
    duration = data['duration'].to_i
    return nil if fingerprint.empty? || duration <= 0

    { :duration => duration, :fingerprint => fingerprint }
  rescue Errno::ENOENT
    log_debug('AcoustID: fpcalc binary not found, skipping fingerprint')
    nil
  rescue StandardError => e
    report_error(e, 'AcoustID fingerprint failed')
    nil
  end

  # --- Pure parser (unit-tested) --------------------------------------------

  def normalize_response(payload)
    return {} unless payload.is_a?(Hash) && payload['status'].to_s == 'ok'

    result = Array(payload['results'])
             .select { |entry| entry.is_a?(Hash) && entry['score'].to_f >= MIN_SCORE }
             .max_by { |entry| entry['score'].to_f }
    recording = Array(result && result['recordings']).find { |rec| rec.is_a?(Hash) }
    return {} unless recording

    release_group = Array(recording['releasegroups']).find { |rg| rg.is_a?(Hash) }
    compact_tags(
      :artist => artist_names(recording['artists']),
      :title => recording['title'].to_s,
      :album => release_group ? release_group['title'].to_s : '',
      :year => year_from(recording),
      :mbid => recording['id'].to_s
    )
  end

  def artist_names(artists)
    Array(artists).map do |artist|
      next '' unless artist.is_a?(Hash)

      "#{artist['name']}#{artist['joinphrase']}"
    end.join.strip
  end

  private

  def query(fingerprint, duration)
    key = "acoustid:#{Digest::SHA1.hexdigest(fingerprint)}"
    return @memo[key] if @memo.key?(key)

    value = begin
      if @cache
        @cache.fetch(key) { fetch_remote(fingerprint, duration) }
      else
        fetch_remote(fingerprint, duration)
      end
    rescue StandardError => e
      report_error(e, 'AcoustID request failed')
      nil
    end
    @memo[key] = value
    value
  end

  def fetch_remote(fingerprint, duration)
    params = {
      client: @api_key,
      duration: duration,
      fingerprint: fingerprint,
      meta: 'recordings+releasegroups+compress',
      format: 'json'
    }
    log_debug("AcoustID request (duration #{duration})")
    response = @http_client.get(BASE_URL, query: params, timeout: @timeout)
    status = response.respond_to?(:code) ? response.code.to_i : nil
    raise StandardError, "AcoustID request failed with status #{status || 'unknown'}" unless status && status.between?(200, 299)

    JSON.parse(response.body.to_s)
  end

  def year_from(recording)
    dates = Array(recording['releasegroups']).flat_map do |rg|
      next [] unless rg.is_a?(Hash)

      [rg['first-release-date'], rg['date']]
    end
    dates.map { |date| date.to_s[/\d{4}/] }.compact.first.to_s
  end

end

# frozen_string_literal: true

require 'json'
require 'date'
require 'httparty'

class ImdbApi
  DEFAULT_BASE_URL = 'https://v3.sg.media-imdb.com'
  DEFAULT_REGION = 'US'

  def initialize(http_client: HTTParty, base_url: nil, region: nil, api_key: nil, speaker: nil)
    @http_client = http_client
    @base_url = (base_url || DEFAULT_BASE_URL).to_s.chomp('/')
    @region = region.to_s.empty? ? DEFAULT_REGION : region.to_s
    @api_key = api_key.to_s.strip
    @speaker = speaker
  end

  def calendar(date_range:, limit: 100)
    return [] unless date_range.respond_to?(:each)

    entries = []

    date_range.each do |date|
      break if entries.length >= limit

      entries.concat(fetch_calendar_for(date))
    end

    entries.first(limit)
  end

  private

  attr_reader :http_client, :base_url, :region, :api_key, :speaker

  def fetch_calendar_for(date)
    path = "#{base_url}/imdb-api/calendar"
    response = http_client.get(
      path,
      query: { date: format_date(date), region: region },
      headers: headers
    )

    status = response.respond_to?(:code) ? response.code.to_i : nil
    verify_response!(response, path, status)

    parse_calendar_response(response&.body, date, path, status)
  end

  def format_date(date)
    return date.strftime('%Y-%m-%d') if date.respond_to?(:strftime)

    Date.parse(date.to_s).strftime('%Y-%m-%d')
  end

  def headers
    return {
      'x-imdb-client-name' => 'imdb-web-next',
      'x-imdb-client-platform' => 'Desktop',
      'Accept' => 'application/json'
    } if api_key.empty?

    {
      'x-imdb-api-key' => api_key,
      'x-imdb-client-name' => 'imdb-web-next',
      'x-imdb-client-platform' => 'Desktop',
      'Accept' => 'application/json'
    }
  end

  def parse_calendar_response(body, fallback_date, path, status)
    payload = parse_json(body, path, status)

    titles = extract_titles(payload)

    Array(titles).filter_map do |title|
      normalize_title(title, fallback_date)
    end
  end

  def parse_json(body, path, status)
    if body.to_s.strip.empty?
      raise_reported_error("IMDb calendar response was empty (status #{status || 'unknown'}) for #{path}")
    end

    JSON.parse(body)
  rescue JSON::ParserError => e
    raise_reported_error("IMDb calendar response for #{path} was invalid JSON (status #{status || 'unknown'}): #{e.message}")
  end

  def verify_response!(response, path, status)
    return if response && status && status.between?(200, 299)

    raise_reported_error("IMDb calendar request failed with status #{status || 'unknown'} for #{path}")
  end

  def raise_reported_error(message)
    error = StandardError.new(message)
    speaker&.tell_error(error, 'IMDb calendar request')
    raise error
  end

  def extract_titles(payload)
    return payload if payload.is_a?(Array)

    return payload['titles'] if payload.is_a?(Hash) && payload['titles'].is_a?(Array)

    array_value = payload.values.find { |value| value.is_a?(Array) } if payload.is_a?(Hash)
    array_value || []
  end

  def normalize_title(title, fallback_date)
    return unless title.is_a?(Hash)

    normalized = title.dup
    normalized['releaseDate'] = normalize_release_date(title, fallback_date)
    normalized
  end

  def normalize_release_date(title, fallback_date)
    return title['releaseDate'] if title['releaseDate']
    return title[:releaseDate] if title.key?(:releaseDate)
    return title[:release_date] if title.key?(:release_date)

    formatted = format_date(fallback_date) if fallback_date
    return formatted unless formatted.nil?

    nil
  end
end

# frozen_string_literal: true

require 'date'
require 'json'
require 'uri'
require 'httparty'

class OmdbApi
  DEFAULT_BASE_URL = 'https://www.omdbapi.com/'.freeze

  attr_reader :last_request_path, :last_response_body

  def initialize(api_key:, base_url: nil, http_client: HTTParty, speaker: nil)
    @api_key = api_key.to_s.strip
    @base_url = (base_url || DEFAULT_BASE_URL).to_s.chomp('/')
    @http_client = http_client
    @speaker = speaker
    @last_request_path = nil
  end

  def calendar(date_range:, limit: 100)
    return [] if @api_key.empty?
    return [] unless date_range.respond_to?(:each)

    results = []
    years(date_range).each do |year|
      break if results.length >= limit

      results.concat(fetch_year(year: year, date_range: date_range, limit: limit - results.length))
    end

    results.first(limit)
  end

  def title(imdb_id)
    return nil if @api_key.empty?
    return nil if imdb_id.to_s.strip.empty?

    normalize_detail(request(detail_query(imdb_id), :title_lookup))
  rescue StandardError => e
    report_error(e, 'OMDb title fetch failed')
    nil
  end

  def find_by_title(title:, year: nil, type: 'movie')
    return nil if @api_key.empty?
    return nil if title.to_s.strip.empty?

    query = { t: title, plot: 'short' }
    query[:y] = year if year
    query[:type] = type if type

    normalize_detail(request(query, :title_search))
  rescue StandardError => e
    report_error(e, 'OMDb title search failed')
    nil
  end

  private

  def years(date_range)
    date_range.map { |date| date.respond_to?(:year) ? date.year : Date.parse(date.to_s).year }.uniq.sort
  end

  def fetch_year(year:, date_range:, limit:)
    results = []
    %w[movie series].each do |type|
      page = 1
      while results.length < limit
        payload = request(search_query(type: type, year: year, page: page), :calendar)
        batch = normalize_search(payload, date_range)
        break if batch.empty?

        results.concat(batch)
        total_results = payload.is_a?(Hash) ? payload['totalResults'].to_i : 0
        break if (page * 10) >= total_results || total_results.zero?

        page += 1
      end
    end
    results
  rescue StandardError => e
    report_error(e, 'OMDb calendar fetch failed')
    []
  end

  def search_query(type:, year:, page: 1)
    { s: '*', type: type, y: year, page: page }
  end

  def detail_query(imdb_id)
    { i: imdb_id, plot: 'short' }
  end

  def request(query, operation = nil)
    query_with_key = query.merge(apikey: @api_key, r: 'json')
    @last_request_path = path_with_query(query_with_key)
    log_debug("OMDb request: #{@last_request_path}")
    response = @http_client.get(@base_url, query: query_with_key)
    status = response.respond_to?(:code) ? response.code.to_i : nil
    @last_response_body = response&.body
    log_debug("OMDb response (status #{status || 'unknown'}): #{truncate_body(@last_response_body)}")
    verify_response!(status, operation)
    parse_json(@last_response_body, status, operation)
  end

  def path_with_query(query)
    uri = URI(@base_url)
    uri.query = URI.encode_www_form(query)
    uri.to_s
  end

  def parse_json(body, status, operation)
    op = operation || 'request'
    text = body.to_s.strip
    raise StandardError, "OMDb #{op} response was empty (status #{status || 'unknown'})" if text.empty?

    JSON.parse(text)
  rescue JSON::ParserError => e
    fallback = tighten_json(text)
    if fallback && fallback != text
      body = fallback
      retry
    end

    report_error(e, "OMDb #{op} response was invalid JSON (status #{status || 'unknown'}): #{e.message}")
    nil
  end

  def verify_response!(status, operation)
    return if status && status.between?(200, 299)

    raise StandardError, "OMDb #{operation || 'request'} request failed with status #{status || 'unknown'}"
  end

  def normalize_search(payload, date_range)
    return [] unless payload.is_a?(Hash)
    return [] if payload['Response'] == 'False'

    records = payload['Search'] || payload['search'] || payload
    Array(records).filter_map { |record| normalize_record(record, date_range) }
  end

  def normalize_detail(record)
    return nil unless record.is_a?(Hash)
    return nil if record['Response'] == 'False'

    imdb_id = value_from(record, :external_id, :imdb_id, :imdbID)
    title = value_from(record, :title, :Title)
    media_type = normalize_type(value_from(record, :media_type, :Type))
    return nil if imdb_id.to_s.strip.empty? || title.to_s.strip.empty? || media_type.empty?

    {
      source: 'omdb',
      external_id: imdb_id.to_s,
      title: title.to_s,
      media_type: media_type,
      genres: list_from(record, :genres, :Genre),
      languages: list_from(record, :languages, :Language),
      countries: list_from(record, :countries, :Country),
      synopsis: value_from(record, :synopsis, :plot, :Plot),
      rating: float_value(value_from(record, :rating, :imdbRating)),
      imdb_votes: votes_value(value_from(record, :imdb_votes, :imdbVotes)),
      poster_url: url_value(value_from(record, :poster_url, :Poster)),
      backdrop_url: url_value(value_from(record, :backdrop_url, :Backdrop)),
      release_date: parse_date(record[:release_date] || record['release_date'] || record['Released'] || record['DVD']),
      ids: ids_for(imdb_id)
    }
  end

  def normalize_record(record, date_range)
    return unless record.is_a?(Hash)

    release_date = parse_date(record[:release_date] || record['release_date'] || record['Released'] || record['DVD'])
    year = release_date&.year || parse_year(value_from(record, :year, :Year))
    return unless year

    year_match = date_range.any? { |date| date.respond_to?(:year) && date.year == year }
    release_date ||= year_match ? parse_date(date_range.first) : Date.new(year, 1, 1)
    return unless release_date && (date_range.cover?(release_date) || year_match)

    imdb_id = value_from(record, :external_id, :imdb_id, :imdbID)
    title = value_from(record, :title, :Title)
    media_type = normalize_type(value_from(record, :media_type, :Type))
    return if imdb_id.to_s.strip.empty? || title.to_s.strip.empty? || media_type.empty?

    {
      source: 'omdb',
      external_id: imdb_id.to_s,
      title: title.to_s,
      media_type: media_type,
      genres: list_from(record, :genres, :Genre),
      languages: list_from(record, :languages, :Language),
      countries: list_from(record, :countries, :Country),
      rating: float_value(value_from(record, :rating, :imdbRating)),
      imdb_votes: votes_value(value_from(record, :imdb_votes, :imdbVotes)),
      poster_url: url_value(value_from(record, :poster_url, :Poster)),
      backdrop_url: url_value(value_from(record, :backdrop_url, :Backdrop)),
      release_date: release_date,
      ids: ids_for(imdb_id)
    }
  end

  def normalize_type(value)
    normalized = value.to_s.downcase
    return 'movie' if normalized == 'movie'
    return 'show' if normalized == 'series' || normalized.include?('series')

    normalized.empty? ? 'movie' : normalized
  end

  def list_from(record, *keys)
    value = value_from(record, *keys)
    return [] if value.nil?

    Array(value.is_a?(String) ? value.split(',') : value)
      .map { |item| item.to_s.strip }
      .reject(&:empty?)
  end

  def float_value(value)
    return nil if value.nil? || value.to_s.strip.empty?

    value.to_f
  rescue StandardError
    nil
  end

  def votes_value(value)
    return nil if value.nil?

    value.to_s.delete(',').to_i
  rescue StandardError
    nil
  end

  def url_value(value)
    url = value.to_s.strip
    url.empty? ? nil : url
  end

  def ids_for(imdb_id)
    imdb_id.to_s.empty? ? {} : { 'imdb' => imdb_id }
  end

  def value_from(record, *keys)
    keys.each do |key|
      next unless key
      value = record[key] || record[key.to_s] || record[key.to_sym]
      return value unless value.nil?
    end
    nil
  end

  def parse_date(value)
    return value if value.is_a?(Date)

    Date.parse(value.to_s)
  rescue StandardError
    nil
  end

  def parse_year(value)
    year = value.to_s[/\d{4}/]
    year ? year.to_i : nil
  end

  def log_debug(message)
    return unless Env.debug?

    @speaker&.speak_up(message)
  rescue StandardError
    nil
  end

  def truncate_body(body)
    body.to_s.length > 400 ? "#{body.to_s[0, 400]}...[truncated]" : body.to_s
  end

  def tighten_json(body)
    closing = body.rindex(/[}\]]/)
    closing ? body[0..closing].gsub(/([\]\}"0-9])\s*"(?=[A-Za-z0-9_]+":)/, '\\1,"') : nil
  end

  def report_error(error, message)
    @speaker&.tell_error(error, message)
  end
end

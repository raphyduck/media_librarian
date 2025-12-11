# frozen_string_literal: true

require 'set'
require 'time'
require 'date'

require_relative '../lib/watchlist_store'
require_relative 'calendar_entries_repository'

class Calendar
  include MediaLibrarian::AppContainerSupport

  CACHE_TTL = 300

  class << self
    def cache
      @cache ||= { data: [], expires_at: nil, mutex: Mutex.new }
    end

    def clear_cache
      cache[:mutex].synchronize do
        cache[:data] = []
        cache[:expires_at] = nil
      end
    end
  end

  def initialize(app: self.class.app)
    self.class.configure(app: app)
    @app = app
  end

  def entries(filters = {})
    result = repository.entries(filters, entries: cached_entries)
    result.merge(entries: result[:entries].map { |entry| serialize_entry(entry) })
  end

  private

  attr_reader :app

  def cached_entries
    storage = cache
    storage[:mutex].synchronize do
      return storage[:data] if storage[:expires_at] && storage[:expires_at] > Time.now

      data = build_entries
      storage[:data] = data
      storage[:expires_at] = Time.now + CACHE_TTL
      data
    end
  end

  def cache
    self.class.cache
  end

  def build_entries
    watchlist_rows = WatchlistStore.fetch
    base_entries = repository.load_entries
    interest_entries = build_calendar_entries(watchlist_rows)
    interest_lookup = build_interest_lookup(watchlist_rows)

    (base_entries + interest_entries)
      .uniq { |entry| normalize_interest_key(entry[:external_id]) }
      .map { |entry| annotate_entry(entry, interest_lookup) }
  end

  def annotate_entry(entry, interest_lookup)
    languages = Array(entry[:languages])
    countries = Array(entry[:countries])
    entry.merge(
      year: entry[:year] || entry[:release_date]&.year,
      language: entry[:language] || languages.find { |lang| !lang.to_s.empty? },
      country: entry[:country] || countries.find { |country| !country.to_s.empty? },
      in_interest_list: interest_lookup.include?(normalize_interest_key(entry[:external_id]))
    )
  end

  def build_calendar_entries(rows)
    rows.each_with_object([]) do |row, memo|
      metadata = normalize_metadata(row[:metadata] || row['metadata'])
      entries = metadata[:calendar_entries] || metadata['calendar_entries']
      next unless entries.is_a?(Array)

      ids = normalize_ids(metadata[:ids] || metadata['ids'])
      entries.each do |entry|
        normalized = normalize_calendar_entry(entry, ids, row)
        memo << normalized if normalized
      end
    end
  rescue StandardError
    []
  end

  def normalize_calendar_entry(entry, ids, parent_row)
    data = entry.is_a?(Hash) ? entry : { title: entry }
    external_id = normalize_interest_key(data[:external_id] || data['external_id'] || parent_row[:external_id] || parent_row['external_id'])
    title = data[:title] || data['title'] || parent_row[:title] || parent_row['title']
    type = normalize_type(data[:type] || data['type'] || parent_row[:type] || parent_row['type'])
    return nil if external_id.empty? || title.to_s.empty? || type.nil?

    {
      source: (data[:source] || data['source'] || 'watchlist').to_s,
      external_id: external_id,
      title: title.to_s,
      type: type,
      release_date: parse_time(data[:release_date] || data['release_date']),
      genres: normalize_list(data[:genres] || data['genres']),
      languages: normalize_list(data[:languages] || data['languages']),
      countries: normalize_list(data[:countries] || data['countries']),
      imdb_rating: parse_rating(data[:imdb_rating] || data['imdb_rating'] || data[:rating] || data['rating']),
      imdb_votes: parse_integer(data[:imdb_votes] || data['imdb_votes']),
      synopsis: data[:synopsis] || data['synopsis'],
      poster_url: normalize_url(data[:poster_url] || data['poster_url'] || data[:poster]),
      backdrop_url: normalize_url(data[:backdrop_url] || data['backdrop_url'] || data[:backdrop]),
      ids: normalize_ids(data[:ids] || data['ids'] || ids),
      in_interest_list: true
    }
  end

  def build_interest_lookup(rows = nil)
    rows ||= WatchlistStore.fetch
    rows.each_with_object(Set.new) do |row, memo|
      external_id = normalize_interest_key(row[:external_id] || row['external_id'])
      memo << external_id unless external_id.empty?

      metadata = normalize_metadata(row[:metadata] || row['metadata'])
      calendar_entries = metadata[:calendar_entries] || metadata['calendar_entries']
      next unless calendar_entries.is_a?(Array)

      calendar_entries.each do |entry|
        entry_id = normalize_interest_key(entry[:external_id] || entry['external_id'])
        memo << entry_id unless entry_id.empty?
      end
    end
  rescue StandardError
    Set.new
  end

  def normalize_metadata(metadata)
    metadata.is_a?(Hash) ? metadata : {}
  end

  def normalize_list(value)
    case value
    when Array
      value.map { |entry| entry.to_s.strip }.reject(&:empty?)
    when String
      value.split(',').map { |entry| entry.to_s.strip }.reject(&:empty?)
    else
      []
    end
  end

  def normalize_type(value)
    case value.to_s.downcase
    when 'movie', 'movies', 'film', 'films'
      'movie'
    when 'show', 'shows', 'tv', 'series'
      'show'
    else
      nil
    end
  end

  def parse_rating(value)
    return nil if value.nil? || value.to_s.strip.empty?

    value.to_f
  end

  def parse_integer(value)
    return nil if value.nil? || value.to_s.strip.empty?

    value.to_i
  end

  def parse_time(value)
    case value
    when Time
      value
    when Date
      Time.utc(value.year, value.month, value.day)
    when String
      return if value.strip.empty?

      Time.parse(value)
    else
      nil
    end
  rescue ArgumentError
    nil
  end

  def normalize_ids(value)
    return {} unless value.is_a?(Hash)

    value.each_with_object({}) do |(key, val), memo|
      key_str = key.to_s
      memo[key_str] = val unless key_str.empty? || val.nil?
    end
  end

  def normalize_interest_key(value)
    value.to_s.strip.downcase
  end

  def repository
    @repository ||= CalendarEntriesRepository.new(app: app)
  end

  def serialize_entry(entry)
    entry.merge(release_date: entry[:release_date]&.iso8601)
  end
end

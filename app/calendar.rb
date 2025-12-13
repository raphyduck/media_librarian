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
    interest_lookup = build_interest_lookup(watchlist_rows)

    base_entries.each_with_object({}) do |entry, memo|
      imdb_id = imdb_id_for(entry)
      next if imdb_id.empty?

      memo[imdb_id] ||= annotate_entry(entry, interest_lookup, imdb_id)
    end.values
  end

  def annotate_entry(entry, interest_lookup, imdb_id = nil)
    languages = Array(entry[:languages])
    countries = Array(entry[:countries])
    imdb_id ||= imdb_id_for(entry)
    ids = normalize_ids(entry[:ids] || entry['ids'])

    entry.merge(
      imdb_id: imdb_id,
      year: entry[:year] || entry[:release_date]&.year,
      language: entry[:language] || languages.find { |lang| !lang.to_s.empty? },
      country: entry[:country] || countries.find { |country| !country.to_s.empty? },
      in_interest_list: interest_lookup.include?(imdb_id)
    )
  end

  def build_interest_lookup(rows = nil)
    rows ||= WatchlistStore.fetch
    rows.each_with_object(Set.new) do |row, memo|
      add_interest_key(memo, row[:imdb_id] || row['imdb_id'])
    end
  rescue StandardError
    Set.new
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

  def add_interest_key(set, value)
    normalized = normalize_interest_key(value)
    set << normalized unless normalized.empty?
  end

  def imdb_id_for(entry)
    ids = normalize_ids(entry[:ids] || entry['ids'])
    pick_imdb_id(entry[:imdb_id] || entry['imdb_id'], ids['imdb'])
  end

  def pick_imdb_id(*values)
    values.each do |value|
      normalized = normalize_interest_key(value)
      return normalized unless normalized.empty?
    end

    ''
  end

  def repository
    @repository ||= CalendarEntriesRepository.new(app: app)
  end

  def serialize_entry(entry)
    entry.merge(release_date: entry[:release_date]&.iso8601)
  end
end

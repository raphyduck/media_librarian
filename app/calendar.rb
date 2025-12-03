# frozen_string_literal: true

require 'set'
require 'time'

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
    base_entries = repository.load_entries
    interest_lookup = build_interest_lookup

    base_entries.map { |entry| annotate_entry(entry, interest_lookup) }
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

  def build_interest_lookup
    rows = WatchlistStore.fetch
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

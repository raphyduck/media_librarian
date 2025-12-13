# frozen_string_literal: true

require 'time'
require 'date'

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
    repository.load_entries.each_with_object({}) do |entry, memo|
      imdb_id = imdb_id_for(entry)
      memo[imdb_id] ||= entry unless imdb_id.empty?
    end.values
  end

  def imdb_id_for(entry)
    ids = entry[:ids] || entry['ids'] || {}
    pick_imdb_id(entry[:imdb_id] || entry['imdb_id'], ids['imdb'])
  end

  def pick_imdb_id(*values)
    values.each do |value|
      normalized = normalize_interest_key(value)
      return normalized unless normalized.empty?
    end

    ''
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

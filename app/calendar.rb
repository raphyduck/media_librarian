# frozen_string_literal: true

require 'set'
require 'time'

require_relative '../lib/watchlist_store'

class Calendar
  include MediaLibrarian::AppContainerSupport

  CACHE_TTL = 300

  class << self
    def cache
      @cache ||= { data: [], expires_at: nil, mutex: Mutex.new }
    end
  end

  def initialize(app: self.class.app)
    self.class.configure(app: app)
    @app = app
  end

  def entries(filters = {})
    filtered = apply_filters(cached_entries, filters)
    sorted = sort_entries(filtered, filters[:sort])
    paginate_entries(sorted, filters[:page], filters[:per_page])
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
    WatchlistStore.fetch.filter_map do |entry|
      type = normalize_entry_type(entry)
      next unless type

      metadata = normalize_metadata(entry)
      ids = extract_ids(metadata)
      medium = load_medium(type, ids)
      next unless medium

      {
        type: type == 'movies' ? 'movie' : 'show',
        title: medium.name,
        year: medium.year,
        genres: Array(medium.genres).compact,
        language: medium.language,
        country: medium.country,
        imdb_rating: safe_rating(medium),
        release_date: release_date_from(metadata, medium, type),
        downloaded: downloaded_from(metadata),
        in_interest_list: true,
        ids: ids
      }
    end
  end

  def normalize_entry_type(entry)
    raw = entry[:type] || entry['type']
    return unless raw

    value = raw.to_s.downcase
    return 'movies' if value.start_with?('movie')
    return 'shows' if value.start_with?('show')
  end

  def normalize_metadata(entry)
    metadata = entry[:metadata] || entry['metadata'] || {}
    metadata.is_a?(Hash) ? metadata : {}
  end

  def extract_ids(metadata)
    ids = metadata[:ids] || metadata['ids'] || {}
    ids.is_a?(Hash) ? ids : {}
  end

  def release_date_from(metadata, medium, type)
    raw = metadata[:release_date] || metadata['release_date']
    raw ||= metadata[:first_aired] || metadata['first_aired']
    raw ||= type == 'movies' ? medium.release_date : medium.first_aired
    parse_date(raw)
  end

  def downloaded_from(metadata)
    return !!metadata[:downloaded] if metadata.key?(:downloaded)
    return !!metadata['downloaded'] if metadata.key?('downloaded')

    !!metadata[:downloaded_at] || !!metadata['downloaded_at']
  end

  def safe_rating(medium)
    value = medium.respond_to?(:rating) ? medium.rating : nil
    value.to_f if value
  end

  def load_medium(type, ids)
    type == 'movies' ? Movie.movie_get(ids, 'movie_get', nil, app: app)[1] : TvSeries.tv_show_get(ids, app: app)[1]
  rescue StandardError
    nil
  end

  def parse_date(value)
    return nil if value.nil?
    return value if value.is_a?(Time)

    Time.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def apply_filters(entries, filters)
    entries.select do |entry|
      type_match?(entry, filters[:type]) &&
        genres_match?(entry, filters[:genres]) &&
        rating_match?(entry, filters[:imdb_min], filters[:imdb_max]) &&
        language_match?(entry, filters[:language]) &&
        country_match?(entry, filters[:country]) &&
        flag_match?(entry[:downloaded], filters[:downloaded]) &&
        flag_match?(entry[:in_interest_list], filters[:interest])
    end
  end

  def type_match?(entry, type_filter)
    return true if type_filter.to_s.empty?

    normalized = type_filter.to_s.downcase
    entry[:type] == normalized || entry[:type] == normalized.chomp('s')
  end

  def genres_match?(entry, genres_filter)
    return true if genres_filter.nil? || genres_filter.empty?

    genres = Array(genres_filter).flat_map { |g| g.to_s.downcase.split(',') }.map(&:strip).reject(&:empty?)
    return true if genres.empty?

    entry_genres = Array(entry[:genres]).map { |g| g.to_s.downcase }
    genres.all? { |genre| entry_genres.include?(genre) }
  end

  def rating_match?(entry, min_rating, max_rating)
    rating = entry[:imdb_rating]
    return true if rating.nil?

    min_ok = min_rating.to_s.empty? || rating >= min_rating.to_f
    max_ok = max_rating.to_s.empty? || rating <= max_rating.to_f
    min_ok && max_ok
  end

  def language_match?(entry, language)
    return true if language.to_s.empty?

    entry[:language].to_s.casecmp?(language.to_s)
  end

  def country_match?(entry, country)
    return true if country.to_s.empty?

    entry[:country].to_s.casecmp?(country.to_s)
  end

  def flag_match?(value, filter)
    return true if filter.nil? || filter.to_s.empty?

    normalized = %w[1 true yes on].include?(filter.to_s.downcase)
    value == normalized
  end

  def sort_entries(entries, sort)
    order = sort.to_s.downcase == 'desc' ? -1 : 1
    entries.sort_by do |entry|
      date = entry[:release_date]
      timestamp = date ? date.to_i : Float::INFINITY
      key = if date
              order == -1 ? -timestamp : timestamp
            else
              Float::INFINITY
            end
      key
    end
  end

  def paginate_entries(entries, page, per_page)
    per_page = clamp_per_page(per_page)
    page = [page.to_i, 1].max
    offset = (page - 1) * per_page
    slice = entries.slice(offset, per_page) || []
    total = entries.size

    {
      entries: slice.map { |entry| serialize_entry(entry) },
      page: page,
      per_page: per_page,
      total: total,
      total_pages: (total.to_f / per_page).ceil
    }
  end

  def clamp_per_page(per_page)
    value = per_page.to_i
    value = 50 if value <= 0
    [value, 200].min
  end

  def serialize_entry(entry)
    entry.merge(release_date: entry[:release_date]&.iso8601)
  end
end

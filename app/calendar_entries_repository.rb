# frozen_string_literal: true

require 'set'
require 'time'

require_relative '../lib/watchlist_store'

class CalendarEntriesRepository
  include MediaLibrarian::AppContainerSupport

  def initialize(app: self.class.app)
    self.class.configure(app: app)
  end

  def entries(filters = {}, entries: nil)
    data = Array(entries || load_entries)
    filtered = apply_filters(data, filters)
    sorted = sort_entries(filtered, filters[:sort])
    paginate_entries(sorted, filters[:page], filters[:per_page])
  end

  def search(title:, year: nil, type: nil)
    return [] if title.to_s.strip.empty?

    needle = normalize_text(title)
    load_entries.select do |entry|
      title_match?(entry[:title], needle) && year_match?(entry, year) && type_match?(entry, type)
    end.uniq { |entry| entry[:imdb_id] }
  end

  def find_by_imdb_id(imdb_id)
    needle = normalize_imdb(imdb_id)
    return if needle.empty?

    load_entries.find do |entry|
      normalize_imdb(entry[:imdb_id]) == needle || normalize_imdb(entry[:external_id]) == needle
    end
  end

  def load_entries
    rows = app.respond_to?(:db) ? Array(app.db&.get_rows(:calendar_entries)) : []
    downloaded_index = build_downloaded_index
    interest_lookup = build_interest_lookup
    rows.filter_map { |row| normalize_row(row, downloaded_index, interest_lookup) }
  rescue StandardError
    []
  end

  private

  def apply_filters(entries, filters)
    title_filter = filters[:title].to_s.strip
    has_title_filter = !title_filter.empty?
    start_date = has_title_filter ? nil : parse_time(filters[:start_date])
    end_date = has_title_filter ? nil : parse_time(filters[:end_date])
    title_needle = has_title_filter ? normalize_text(title_filter) : ''

    entries.select do |entry|
      (!has_title_filter || title_filter_match?(entry[:title], title_needle)) &&
        release_date_match?(entry[:release_date], start_date, end_date) &&
        type_match?(entry, filters[:type]) &&
        genres_match?(entry, filters[:genres]) &&
        rating_match?(entry, filters[:imdb_min], filters[:imdb_max]) &&
        votes_match?(entry, filters[:imdb_votes_min], filters[:imdb_votes_max]) &&
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

  def year_match?(entry, year)
    return true unless year

    release_year = entry[:release_date]&.year || entry[:year]
    release_year.to_i == year.to_i
  end

  def title_match?(value, needle)
    normalize_text(value) == needle
  end

  def title_filter_match?(value, needle)
    return true if needle.empty?

    normalize_text(value).include?(needle)
  end

  def normalize_text(value)
    value.to_s.strip.downcase
  end

  def genres_match?(entry, genres_filter)
    return true if genres_filter.nil? || genres_filter.empty?

    genres = Array(genres_filter)
             .flat_map { |g| g.to_s.downcase.split(',') }
             .map(&:strip)
             .reject(&:empty?)
    return true if genres.empty?

    entry_genres = Array(entry[:genres]).map { |g| g.to_s.downcase }
    (entry_genres & genres).any?
  end

  def rating_match?(entry, min_rating, max_rating)
    rating = entry[:imdb_rating]
    return true if rating.nil?

    min_ok = min_rating.to_s.empty? || rating >= min_rating.to_f
    max_ok = max_rating.to_s.empty? || rating <= max_rating.to_f
    min_ok && max_ok
  end

  def votes_match?(entry, min_votes, max_votes)
    votes = entry[:imdb_votes]
    return min_votes.to_s.empty? && max_votes.to_s.empty? if votes.nil?

    min_ok = min_votes.to_s.empty? || votes >= min_votes.to_i
    max_ok = max_votes.to_s.empty? || votes <= max_votes.to_i
    min_ok && max_ok
  end

  def language_match?(entry, language)
    return true if language.to_s.empty?

    entry[:language].to_s.casecmp?(language.to_s)
  end

  def release_date_match?(release_date, start_date, end_date)
    return true unless start_date || end_date
    return false unless release_date

    after_start = start_date.nil? || release_date >= start_date
    before_end = end_date.nil? || release_date <= end_date
    after_start && before_end
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
      order == -1 ? -timestamp : timestamp
    end
  end

  def paginate_entries(entries, page, per_page)
    per_page = clamp_per_page(per_page)
    page = [page.to_i, 1].max
    offset = (page - 1) * per_page
    slice = entries.slice(offset, per_page) || []
    total = entries.size

    {
      entries: slice,
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

  def normalize_row(row, downloaded_index = nil, interest_lookup = nil)
    type = normalize_type(row[:media_type] || row['media_type'] || row[:type] || row['type'])
    title = (row[:title] || row['title']).to_s.strip
    return unless type && !title.empty?

    release_date = parse_time(row[:release_date] || row['release_date'])
    genres = normalize_list(row[:genres] || row['genres'])
    languages = normalize_list(row[:languages] || row['languages'])
    countries = normalize_list(row[:countries] || row['countries'])
    poster_url = normalize_url(row[:poster_url] || row['poster_url'])
    backdrop_url = normalize_url(row[:backdrop_url] || row['backdrop_url'])
    ids = normalize_ids(row[:ids] || row['ids'])
    ids = build_default_ids(row, ids) if ids.empty?
    imdb_id = (row[:imdb_id] || row['imdb_id']).to_s.strip

    {
      type: type,
      title: title,
      year: release_date&.year,
      genres: genres,
      languages: languages,
      countries: countries,
      language: languages.find { |lang| !lang.to_s.empty? },
      country: countries.find { |country| !country.to_s.empty? },
      imdb_id: imdb_id,
      imdb_rating: parse_rating(row[:rating] || row['rating']),
      imdb_votes: parse_integer(row[:imdb_votes] || row['imdb_votes']),
      synopsis: normalize_synopsis(row[:synopsis] || row['synopsis']),
      release_date: release_date,
      downloaded: downloaded?(row, type, ids, downloaded_index),
      in_interest_list: interest_lookup&.include?(normalize_imdb(imdb_id)),
      poster_url: poster_url,
      backdrop_url: backdrop_url,
      ids: ids,
      source: (row[:source] || row['source']).to_s,
      external_id: (row[:external_id] || row['external_id']).to_s
    }
  end

  def downloaded?(row, type, ids, downloaded_index)
    return true if row[:downloaded] || row['downloaded']

    downloaded_from_inventory?(type, ids, row, downloaded_index)
  end

  def downloaded_from_inventory?(type, ids, row, downloaded_index)
    return false unless downloaded_index && type

    imdb_id = normalize_imdb(extract_imdb_id(ids, row))
    return false if imdb_id.empty?

    downloaded_index[type]&.include?(imdb_id)
  end

  def extract_imdb_id(ids, row)
    (ids['imdb'] || ids[:imdb] || row[:imdb_id] || row['imdb_id']).to_s.strip
  end

  def build_downloaded_index
    database = app.respond_to?(:db) ? app.db : nil
    return {} unless database&.respond_to?(:table_exists?) && database.table_exists?(:local_media)
    return {} unless database.respond_to?(:get_rows)

    rows = Array(database.get_rows(:local_media))
    rows.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |row, memo|
      type = normalize_type(row[:media_type] || row['media_type'])
      imdb_id = normalize_imdb(row[:imdb_id] || row['imdb_id'])
      memo[type] << imdb_id unless type.nil? || imdb_id.empty?
    end
  rescue StandardError
    {}
  end

  def build_interest_lookup
    rows = WatchlistStore.fetch
    rows.each_with_object(Set.new) do |row, memo|
      imdb_id = normalize_imdb(row[:imdb_id] || row['imdb_id'])
      memo << imdb_id unless imdb_id.empty?
    end
  rescue StandardError
    nil
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

  def normalize_url(value)
    url = value.to_s.strip
    url.empty? ? nil : url
  end

  def normalize_synopsis(value)
    text = value.to_s.strip
    text.empty? ? nil : text
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

  def normalize_imdb(value)
    value.to_s.strip.downcase
  end

  def build_default_ids(row, ids)
    source = (row[:source] || row['source']).to_s
    external_id = (row[:external_id] || row['external_id']).to_s
    return ids if source.empty? || external_id.empty?

    ids.merge(source => external_id)
  end
end

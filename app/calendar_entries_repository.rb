# frozen_string_literal: true

require 'time'

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

  def load_entries
    rows = app.respond_to?(:db) ? Array(app.db&.get_rows(:calendar_entries)) : []
    rows.filter_map { |row| normalize_row(row) }
  rescue StandardError
    []
  end

  private

  def apply_filters(entries, filters)
    start_date = parse_time(filters[:start_date])
    end_date = parse_time(filters[:end_date])

    entries.select do |entry|
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

  def normalize_row(row)
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

    {
      type: type,
      title: title,
      year: release_date&.year,
      genres: genres,
      languages: languages,
      countries: countries,
      language: languages.find { |lang| !lang.to_s.empty? },
      country: countries.find { |country| !country.to_s.empty? },
      imdb_rating: parse_rating(row[:rating] || row['rating']),
      imdb_votes: parse_integer(row[:imdb_votes] || row['imdb_votes']),
      release_date: release_date,
      downloaded: !!(row[:downloaded] || row['downloaded']),
      in_interest_list: !!(row[:in_interest_list] || row['in_interest_list']),
      poster_url: poster_url,
      backdrop_url: backdrop_url,
      ids: ids,
      source: (row[:source] || row['source']).to_s,
      external_id: (row[:external_id] || row['external_id']).to_s
    }
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

  def build_default_ids(row, ids)
    source = (row[:source] || row['source']).to_s
    external_id = (row[:external_id] || row['external_id']).to_s
    return ids if source.empty? || external_id.empty?

    ids.merge(source => external_id)
  end
end

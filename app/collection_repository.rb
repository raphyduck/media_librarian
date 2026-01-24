# frozen_string_literal: true

require 'json'
require 'time'
require 'sequel'

class CollectionRepository
  include MediaLibrarian::AppContainerSupport

  DEFAULT_PER_PAGE = 50
  MAX_PER_PAGE = 200

  def initialize(app: self.class.app)
    self.class.configure(app: app)
  end

  def paginated_entries(sort:, page:, per_page: DEFAULT_PER_PAGE, search: '', type: nil)
    dataset = apply_type_filter(collection_dataset, type)
    dataset = apply_search(dataset, search)
    return empty_response(page, per_page) unless dataset

    per_page = clamp_per_page(per_page)
    page = normalize_page(page)
    ordered = apply_sort(dataset, sort)
    aggregated = aggregate_rows(ordered.all)
    total = aggregated.size
    entries = aggregated.slice(offset(page, per_page), per_page) || []

    { entries: entries, total: total, page: page, per_page: per_page }
  rescue StandardError
    empty_response(page, per_page)
  end

  private

  def aggregate_rows(rows)
    groups = {}
    order = []

    rows.each do |row|
      key = group_key(row)
      next if key.empty?

      order << key unless groups.key?(key)
      (groups[key] ||= []) << row
    end

    series_rows = all_show_series_rows(rows)
    order.map { |key| serialize_group(groups[key], key, series_rows) }
  end

  def apply_sort(dataset, sort)
    created_at = Sequel[:local_media][:created_at]
    local_path = Sequel[:local_media][:local_path]

    case sort
    when 'title'
      dataset.order(Sequel.asc(local_path))
    when 'released_at', 'year'
      dataset.order(Sequel.desc(created_at), Sequel.asc(local_path))
    else
      dataset.order(Sequel.desc(created_at))
    end
  end

  def apply_search(dataset, search)
    return dataset unless dataset && search.to_s.strip != ''

    pattern = "%#{search.to_s.strip}%"
    conditions = [
      Sequel.ilike(Sequel[:local_media][:local_path], pattern),
      Sequel.ilike(Sequel[:local_media][:imdb_id], pattern)
    ]
    conditions << Sequel.ilike(Sequel[:calendar_entries][:title], pattern) if calendar_column?(:title)

    dataset.where(Sequel.|(*conditions))
  end

  def clamp_per_page(per_page)
    value = per_page.to_i
    value = DEFAULT_PER_PAGE if value <= 0
    [value, MAX_PER_PAGE].min
  end

  def apply_type_filter(dataset, type)
    return dataset unless dataset
    return dataset if type.to_s.strip.empty? || type == 'all'

    if %w[movie show].include?(type)
      dataset.where(Sequel[:local_media][:media_type] => type)
    elsif type == 'unmatched'
      imdb_id = Sequel[:local_media][:imdb_id]
      conditions = [imdb_id => nil, imdb_id => '']
      if local_media_column?(:matched)
        conditions << { Sequel[:local_media][:matched] => false }
      end
      dataset.where(Sequel.|(*conditions))
    else
      dataset
    end
  end

  def collection_dataset
    return unless app.respond_to?(:db) && app.db.respond_to?(:database)
    return if app.db.respond_to?(:table_exists?) && !app.db.table_exists?(:local_media)

    dataset = app.db.database[:local_media].select_all(:local_media)
    return dataset unless calendar_table?

    dataset = dataset.left_join(:calendar_entries, Sequel[:calendar_entries][:imdb_id] => Sequel[:local_media][:imdb_id])
    selections = []
    selections << Sequel[:calendar_entries][:title].as(:calendar_title) if calendar_column?(:title)
    selections << Sequel[:calendar_entries][:release_date] if calendar_column?(:release_date)
    selections << Sequel[:calendar_entries][:poster_url] if calendar_column?(:poster_url)
    selections << Sequel[:calendar_entries][:backdrop_url] if calendar_column?(:backdrop_url)
    selections << Sequel[:calendar_entries][:synopsis] if calendar_column?(:synopsis)
    selections << Sequel[:calendar_entries][:ids] if calendar_column?(:ids)
    selections << Sequel[:calendar_entries][:source] if calendar_column?(:source)
    selections << Sequel[:calendar_entries][:external_id] if calendar_column?(:external_id)
    selections.any? ? dataset.select_append(*selections) : dataset
  end

  def empty_response(page, per_page)
    { entries: [], total: 0, page: normalize_page(page), per_page: clamp_per_page(per_page) }
  end

  def normalize_page(page)
    value = page.to_i
    value = 1 if value <= 0
    value
  end

  def offset(page, per_page)
    (page - 1) * per_page
  end

  def serialize_group(rows, group_key = nil, series_rows = {})
    primary = rows.first
    series_title = series_title(rows, group_key) if fetch(primary, :media_type) == 'show'
    entry = {
      id: fetch(primary, :id),
      media_type: fetch(primary, :media_type),
      imdb_id: fetch(primary, :imdb_id),
      title: series_title || derived_title(primary),
      name: series_title || derived_title(primary),
      released_at: build_released_at(fetch(primary, :release_date) || fetch(primary, :created_at)),
      year: extract_year(fetch(primary, :release_date)),
      poster_url: fetch(primary, :poster_url),
      backdrop_url: fetch(primary, :backdrop_url),
      synopsis: fetch(primary, :synopsis),
      ids: normalize_ids(fetch(primary, :ids)),
      source: fetch(primary, :source),
      external_id: fetch(primary, :external_id),
      local_path: fetch(primary, :local_path),
      created_at: fetch(primary, :created_at),
      files: rows.map { |row| fetch(row, :local_path) }.compact
    }.compact

    if entry[:media_type] == 'show'
      entry[:seasons] = build_seasons(series_rows[group_key] || rows)
    end
    entry
  end

  def all_show_series_rows(rows)
    return {} unless rows.any? { |row| fetch(row, :media_type) == 'show' }
    return {} unless app.respond_to?(:db) && app.db.respond_to?(:database)

    dataset = app.db.database[:local_media]
    return {} if app.db.respond_to?(:table_exists?) && !app.db.table_exists?(:local_media)

    grouped = Hash.new { |h, k| h[k] = [] }
    dataset.where(media_type: 'show').select(:local_path).all.each do |row|
      key = series_key(row)
      next if key.empty?

      grouped[key] << row
    end
    grouped
  end

  def group_key(row)
    if fetch(row, :media_type) == 'show'
      series = series_key(row)
      return series unless series.empty?
    end

    key = fetch(row, :imdb_id).to_s
    key = fetch(row, :id).to_s if key.empty?
    key
  end

  def series_key(row)
    series = series_name_from(row)
    series.empty? ? '' : series.downcase
  end

  def fetch(row, key)
    row[key] || row[key.to_s]
  end

  def derived_title(row)
    fetch(row, :calendar_title) || File.basename(fetch(row, :local_path).to_s)
  end

  def series_title(rows, group_key)
    calendar_title = rows.map { |row| fetch(row, :calendar_title) }.find { |value| value.to_s.strip != '' }
    return calendar_title if calendar_title

    name = rows.map { |row| series_name_from(row) }.find { |value| value.to_s.strip != '' }
    return name if name

    group_key.to_s
  end

  def series_name_from(row)
    source = fetch(row, :calendar_title).to_s
    source = File.basename(fetch(row, :local_path).to_s) if source.empty?
    return '' if source.empty?

    if (match = source.match(/(.+?)[ ._-]*[sS]\d{1,2}[ ._-]*[eE]\d{1,2}/))
      return normalize_series_name(match[1])
    end

    if (match = source.match(/(.+?)\d{1,2}x\d{1,2}/))
      return normalize_series_name(match[1])
    end

    normalize_series_name(source)
  end

  def normalize_series_name(value)
    value.to_s.tr('._', ' ').gsub(/\s+/, ' ').strip
  end

  def build_released_at(value)
    return nil if value.nil?

    if value.is_a?(Date)
      return Time.utc(value.year, value.month, value.day).iso8601
    end

    Time.parse(value.to_s).utc.iso8601
  rescue StandardError
    nil
  end

  def extract_year(value)
    date = value.is_a?(Date) ? value : Time.parse(value.to_s)
    date.year
  rescue StandardError
    nil
  end

  def build_seasons(rows)
    episodes = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }

    rows.each do |row|
      season, episode = extract_season_episode(row)
      next unless season && episode

      episodes[season][episode] << fetch(row, :local_path)
    end

    episodes
      .sort_by { |season, _| season }
      .map do |season, eps|
        {
          season: season,
          episodes: eps.sort_by { |episode, _| episode }.map { |episode, files| { episode: episode, files: files.compact } }
        }
      end
  end

  def extract_season_episode(row)
    source = fetch(row, :local_path).to_s
    return if source.empty?

    if (match = source.match(/[sS](\d{1,2})[ ._-]*[eE](\d{1,2})/))
      return match[1].to_i, match[2].to_i
    end

    if (match = source.match(/(\d{1,2})x(\d{1,2})/))
      return match[1].to_i, match[2].to_i
    end
  end

  def normalize_ids(value)
    return value if value.is_a?(Hash)

    parsed = JSON.parse(value) if value.is_a?(String) && value.strip.start_with?('{', '[')
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def calendar_table?
    app.respond_to?(:db) && app.db.respond_to?(:table_exists?) && app.db.table_exists?(:calendar_entries)
  end

  def local_media_column?(name)
    local_media_columns.include?(name)
  end

  def calendar_column?(name)
    calendar_columns.include?(name)
  end

  def local_media_columns
    return @local_media_columns if defined?(@local_media_columns)
    return @local_media_columns = [] unless app.respond_to?(:db) && app.db.respond_to?(:database)
    return @local_media_columns = [] if app.db.respond_to?(:table_exists?) && !app.db.table_exists?(:local_media)

    @local_media_columns = app.db.database[:local_media].columns
  end

  def calendar_columns
    return @calendar_columns if defined?(@calendar_columns)
    return @calendar_columns = [] unless calendar_table?

    @calendar_columns = app.db.database[:calendar_entries].columns
  end
end

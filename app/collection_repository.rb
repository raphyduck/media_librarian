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
      key = fetch(row, :imdb_id).to_s
      key = fetch(row, :id).to_s if key.empty?
      next if key.empty?

      order << key unless groups.key?(key)
      (groups[key] ||= []) << row
    end

    order.map { |key| serialize_group(groups[key]) }
  end

  def apply_sort(dataset, sort)
    case sort
    when 'title'
      dataset.order(Sequel.asc(:local_path))
    when 'released_at', 'year'
      dataset.order(Sequel.desc(:created_at), Sequel.asc(:local_path))
    else
      dataset.order(Sequel.desc(:created_at))
    end
  end

  def apply_search(dataset, search)
    return dataset unless dataset && search.to_s.strip != ''

    pattern = "%#{search.strip}%"
    dataset.where(Sequel.ilike(:local_path, pattern) | Sequel.ilike(:imdb_id, pattern))
  end

  def clamp_per_page(per_page)
    value = per_page.to_i
    value = DEFAULT_PER_PAGE if value <= 0
    [value, MAX_PER_PAGE].min
  end

  def apply_type_filter(dataset, type)
    return dataset unless dataset
    return dataset if type.to_s.strip.empty? || type == 'all'

    %w[movie tv].include?(type) ? dataset.where(media_type: type) : dataset
  end

  def collection_dataset
    return unless app.respond_to?(:db) && app.db.respond_to?(:database)
    return if app.db.respond_to?(:table_exists?) && !app.db.table_exists?(:local_media)

    dataset = app.db.database[:local_media].select_all(:local_media)
    return dataset unless calendar_table?

    dataset
      .left_join(:calendar_entries, Sequel[:calendar_entries][:imdb_id] => Sequel[:local_media][:imdb_id])
      .select_append(
        Sequel[:calendar_entries][:title],
        Sequel[:calendar_entries][:release_date],
        Sequel[:calendar_entries][:poster_url],
        Sequel[:calendar_entries][:backdrop_url],
        Sequel[:calendar_entries][:synopsis],
        Sequel[:calendar_entries][:ids],
        Sequel[:calendar_entries][:source],
        Sequel[:calendar_entries][:external_id]
      )
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

  def serialize_group(rows)
    primary = rows.first
    entry = {
      id: fetch(primary, :id),
      media_type: fetch(primary, :media_type),
      imdb_id: fetch(primary, :imdb_id),
      title: derived_title(primary),
      name: fetch(primary, :title) || derived_title(primary),
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

    entry[:seasons] = build_seasons(rows) if entry[:media_type] == 'tv'
    entry
  end

  def fetch(row, key)
    row[key] || row[key.to_s]
  end

  def derived_title(row)
    fetch(row, :title) || File.basename(fetch(row, :local_path).to_s)
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
end

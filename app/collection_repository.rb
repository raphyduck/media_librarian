# frozen_string_literal: true

require 'time'
require 'sequel'

class CollectionRepository
  include MediaLibrarian::AppContainerSupport

  DEFAULT_PER_PAGE = 50
  MAX_PER_PAGE = 200

  def initialize(app: self.class.app)
    self.class.configure(app: app)
  end

  def paginated_entries(sort:, page:, per_page: DEFAULT_PER_PAGE, search: '')
    dataset = apply_search(collection_dataset, search)
    return empty_response(page, per_page) unless dataset

    per_page = clamp_per_page(per_page)
    page = normalize_page(page)
    ordered = apply_sort(dataset, sort)
    total = ordered.unlimited.count
    entries = ordered.limit(per_page, offset(page, per_page)).all

    { entries: entries.map { |row| serialize_row(row) }, total: total }
  rescue StandardError
    empty_response(page, per_page)
  end

  private

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

  def collection_dataset
    return unless app.respond_to?(:db) && app.db.respond_to?(:database)
    return if app.db.respond_to?(:table_exists?) && !app.db.table_exists?(:local_media)

    app.db.database[:local_media]
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

  def serialize_row(row)
    {
      id: fetch(row, :id),
      media_type: fetch(row, :media_type),
      imdb_id: fetch(row, :imdb_id),
      title: derived_title(row),
      released_at: build_released_at(fetch(row, :created_at)),
      local_path: fetch(row, :local_path),
      created_at: fetch(row, :created_at)
    }.compact
  end

  def fetch(row, key)
    row[key] || row[key.to_s]
  end

  def derived_title(row)
    File.basename(fetch(row, :local_path).to_s)
  end

  def build_released_at(value)
    return nil if value.nil?

    Time.parse(value.to_s).utc.iso8601
  rescue StandardError
    nil
  end
end

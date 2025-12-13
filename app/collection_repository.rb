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
      dataset.order(Sequel.asc(:title))
    when 'released_at', 'year'
      dataset.order(Sequel.desc(:year), Sequel.asc(:title))
    else
      dataset
    end
  end

  def apply_search(dataset, search)
    return dataset unless dataset && search.to_s.strip != ''

    dataset.where(Sequel.ilike(:title, "%#{search.strip}%"))
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
    year = parse_year(row)
    {
      id: fetch(row, :id),
      media_type: fetch(row, :media_type),
      title: fetch(row, :title),
      year: year,
      released_at: build_released_at(year),
      external_id: fetch(row, :external_id),
      external_source: fetch(row, :external_source),
      local_path: fetch(row, :local_path),
      created_at: fetch(row, :created_at)
    }.compact
  end

  def fetch(row, key)
    row[key] || row[key.to_s]
  end

  def parse_year(row)
    value = fetch(row, :year)
    return nil if value.nil?

    int_value = value.to_i
    int_value.positive? ? int_value : nil
  end

  def build_released_at(year)
    return nil unless year

    Time.utc(year, 1, 1).iso8601
  rescue RangeError
    nil
  end
end

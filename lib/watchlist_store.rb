# frozen_string_literal: true

require 'date'

module WatchlistStore
  module_function

  def upsert(entries)
    rows = filter_rows_with_calendar_entries(normalize_entries(entries))
    rows.each { |row| MediaLibrarian.app.db.insert_row('watchlist', row, 1) }
    rows.length
  rescue StandardError => e
    MediaLibrarian.app.speaker.tell_error(e, 'WatchlistStore.upsert') rescue nil
    0
  end

  def fetch(type: nil)
    conditions = {}
    conditions[:type] = type if type && !type.to_s.empty?
    MediaLibrarian.app.db.get_rows('watchlist', conditions)
  rescue StandardError => e
    MediaLibrarian.app.speaker.tell_error(e, 'WatchlistStore.fetch') rescue nil
    []
  end

  def fetch_with_details(type: nil)
    rows = fetch(type: type)
    return rows if rows.empty?

    imdb_ids = rows.filter_map { |row| normalize_imdb(row[:imdb_id] || row['imdb_id']) }.uniq
    return rows if imdb_ids.empty?

    calendar_rows = MediaLibrarian.app.db.get_rows('calendar_entries', imdb_id: imdb_ids)
    calendar_index = build_calendar_index(calendar_rows)

    rows.filter_map do |row|
      imdb_id = normalize_imdb(row[:imdb_id] || row['imdb_id'])
      calendar_row = calendar_index[imdb_id]
      next unless calendar_row

      merge_calendar_data(row, calendar_row)
    end
  rescue StandardError => e
    MediaLibrarian.app.speaker.tell_error(e, 'WatchlistStore.fetch_with_details') rescue nil
    rows
  end

  def delete(imdb_id: nil, type: nil)
    identifier = imdb_id.to_s.strip
    return 0 if identifier.empty?

    conditions = { imdb_id: identifier }
    conditions[:type] = type if type && !type.to_s.empty?
    MediaLibrarian.app.db.delete_rows('watchlist', conditions).to_i
  rescue StandardError => e
    MediaLibrarian.app.speaker.tell_error(e, 'WatchlistStore.delete') rescue nil
    0
  end

  def normalize_entries(entries)
    Array(entries).filter_map do |entry|
      next unless entry.is_a?(Hash)

      metadata = normalize_metadata(entry[:metadata] || entry['metadata'])
      imdb_id = imdb_id_for(entry, metadata)
      imdb_id = (entry[:external_id] || entry['external_id']).to_s.strip if imdb_id.empty?

      title = (entry[:title] || entry['title']).to_s.strip
      type = normalize_type(entry[:type] || entry['type'] || 'movies')
      next if imdb_id.empty? || type.empty? || !valid_title?(title, imdb_id)

      {
        imdb_id: imdb_id,
        type: type,
        updated_at: Time.now.utc
      }
    end
  end

  def valid_title?(title, identifier = nil)
    normalized_title = title.to_s.strip
    return false if normalized_title.empty?

    normalized_id = identifier.to_s.strip
    return false if !normalized_id.empty? && normalized_title == normalized_id

    true
  end

  def normalize_metadata(metadata)
    return {} unless metadata.is_a?(Hash)

    metadata.transform_keys(&:to_sym)
  end

  def imdb_id_for(entry, metadata)
    explicit_imdb = entry[:imdb_id] || entry['imdb_id']
    return explicit_imdb.to_s.strip if explicit_imdb

    ids = metadata[:ids] || metadata['ids'] || {}
    return '' unless ids.is_a?(Hash)

    (ids[:imdb] || ids['imdb']).to_s.strip
  end

  def normalize_type(type)
    type.to_s.strip
  end

  def normalize_imdb(value)
    value.to_s.strip
  end

  def build_calendar_index(rows)
    Array(rows).each_with_object({}) do |row, memo|
      imdb = normalize_imdb(row[:imdb_id] || row['imdb_id'])
      memo[imdb] = row unless imdb.empty?
    end
  end

  def filter_rows_with_calendar_entries(rows)
    return rows unless calendar_table?
    return [] if rows.empty?

    imdb_ids = rows.filter_map { |row| normalize_imdb(row[:imdb_id]) }.uniq
    return [] if imdb_ids.empty?

    calendar_rows = MediaLibrarian.app.db.get_rows('calendar_entries', imdb_id: imdb_ids)
    calendar_index = build_calendar_index(calendar_rows)
    rows.select { |row| calendar_index.key?(normalize_imdb(row[:imdb_id])) }
  end

  def calendar_table?
    MediaLibrarian.app&.db&.respond_to?(:table_exists?) &&
      MediaLibrarian.app.db.table_exists?(:calendar_entries)
  end

  def merge_calendar_data(row, calendar_row)
    base = {
      imdb_id: normalize_imdb(row[:imdb_id] || row['imdb_id']),
      type: normalize_type(row[:type] || row['type']),
      created_at: row[:created_at] || row['created_at'],
      updated_at: row[:updated_at] || row['updated_at']
    }

    return base unless calendar_row

    ids = normalize_ids(calendar_row[:ids] || calendar_row['ids'])
    ids['imdb'] ||= base[:imdb_id]
    release_date = calendar_row[:release_date] || calendar_row['release_date']

    base.merge(
      title: (calendar_row[:title] || calendar_row['title']).to_s,
      ids: ids,
      year: extract_year(release_date),
      release_date: release_date,
      type: normalize_type(base[:type].empty? ? (calendar_row[:media_type] || calendar_row['media_type']) : base[:type]),
      source: calendar_row[:source] || calendar_row['source'],
      url: calendar_row[:url] || calendar_row['url']
    )
  end

  def normalize_ids(ids)
    return {} unless ids.is_a?(Hash)

    ids.each_with_object({}) do |(key, value), memo|
      memo[key.to_s] = value unless key.to_s.strip.empty?
    end
  end

  def extract_year(release_date)
    return release_date.year if release_date.respond_to?(:year)
    return nil unless release_date.respond_to?(:to_s)

    date = release_date.to_s[0, 10]
    Date.parse(date).year
  rescue StandardError
    nil
  end

  private_class_method :normalize_entries, :normalize_metadata, :imdb_id_for,
                       :normalize_type, :normalize_imdb, :build_calendar_index,
                       :merge_calendar_data, :normalize_ids, :extract_year,
                       :filter_rows_with_calendar_entries, :calendar_table?
end

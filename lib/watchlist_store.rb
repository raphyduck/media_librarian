# frozen_string_literal: true

module WatchlistStore
  module_function

  def upsert(entries)
    rows = normalize_entries(entries)
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

  def delete(external_id: nil, imdb_id: nil, type: nil)
    conditions = {}
    conditions[:imdb_id] = imdb_id.to_s if imdb_id && !imdb_id.to_s.empty?
    conditions[:external_id] = external_id.to_s if conditions.empty?
    return 0 if conditions.empty?
    conditions[:type] = type if type && !type.to_s.empty?
    MediaLibrarian.app.db.delete_rows('watchlist', conditions).to_i
  rescue StandardError => e
    MediaLibrarian.app.speaker.tell_error(e, 'WatchlistStore.delete') rescue nil
    0
  end

  def normalize_entries(entries)
    Array(entries).filter_map do |entry|
      next unless entry

      metadata = normalize_metadata(entry[:metadata] || entry['metadata'])
      imdb_id = imdb_id_for(entry, metadata)
      external_id = (entry[:external_id] || entry['external_id'] || imdb_id).to_s
      imdb_id = external_id if imdb_id.to_s.empty?

      title = entry[:title] || entry['title']
      type = entry[:type] || entry['type'] || 'movies'
      next if imdb_id.to_s.empty? || title.to_s.empty?

      {
        external_id: external_id,
        imdb_id: imdb_id,
        type: type.to_s,
        title: title.to_s,
        metadata: metadata,
        updated_at: Time.now.utc
      }
    end
  end

  def normalize_metadata(metadata)
    return {} unless metadata.is_a?(Hash)

    metadata
  end

  def imdb_id_for(entry, metadata)
    explicit_imdb = entry[:imdb_id] || entry['imdb_id']
    return explicit_imdb.to_s if explicit_imdb

    ids = metadata[:ids] || metadata['ids'] || {}
    return '' unless ids.is_a?(Hash)

    (ids[:imdb] || ids['imdb']).to_s
  end
  private_class_method :normalize_entries, :normalize_metadata, :imdb_id_for
end

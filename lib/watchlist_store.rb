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

  def normalize_entries(entries)
    Array(entries).filter_map do |entry|
      next unless entry

      external_id = entry[:external_id] || entry['external_id']
      title = entry[:title] || entry['title']
      type = entry[:type] || entry['type'] || 'movies'
      next if external_id.to_s.empty? || title.to_s.empty?

      metadata = entry[:metadata] || entry['metadata'] || {}
      metadata = {} unless metadata.is_a?(Hash)

      {
        external_id: external_id.to_s,
        type: type.to_s,
        title: title.to_s,
        metadata: metadata,
        updated_at: Time.now.utc
      }
    end
  end
  private_class_method :normalize_entries
end

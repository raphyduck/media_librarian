# frozen_string_literal: true

class LocalMediaRepository
  include MediaLibrarian::AppContainerSupport

  def initialize(app: self.class.app)
    self.class.configure(app: app)
  end

  def library_index(type:, folder: nil)
    rows = fetch_rows(type, folder)
    rows.each_with_object({}) do |row, memo|
      identifiers = build_identifiers(row)
      next if identifiers.empty?

      file = { type: 'file', name: row[:local_path], f_type: type, parts: [row[:local_path]] }
      attrs = { obj_title: inferred_title(row), f_type: type }
      Metadata.media_add(identifiers.first, type, identifiers.first, identifiers, attrs, { f_type: type }, file, memo)
    end
  end

  private

  def build_identifiers(row)
    id = (row[:imdb_id] || row['imdb_id'] || row[:external_id] || row['external_id']).to_s
    return [] if id.empty?

    [id]
  end

  def fetch_rows(type, folder)
    return [] unless app&.respond_to?(:db)

    additionals = {}
    if folder.to_s != ''
      normalized = File.expand_path(folder.to_s)
      additionals['local_path like'] = "#{normalized}%"
    end

    app.db.get_rows(:local_media, { media_type: type.to_s }, additionals)
  rescue StandardError => e
    app&.speaker&.tell_error(e, Utils.arguments_dump(binding)) if app&.respond_to?(:speaker)
    []
  end

  def inferred_title(row)
    File.basename(row[:local_path].to_s)
  end
end

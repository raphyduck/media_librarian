# frozen_string_literal: true

require 'json'

Sequel.migration do
  up do
    break unless table_exists?(:local_media)

    alter_table(:local_media) do
      add_column :imdb_id, String, text: true, null: false, default: ''
    end

    parse_ids = lambda do |value|
      parsed = value
      parsed = JSON.parse(value) if value.is_a?(String) && value.strip.start_with?('{', '[')
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError
      {}
    end

    extract_sources = lambda do |row, ids|
      sources = []
      source = (row[:source] || row['source']).to_s.downcase
      external_id = (row[:external_id] || row['external_id']).to_s.strip
      sources << [source, external_id] unless source.empty? || external_id.empty?

      ids.each do |key, value|
        key_name = key.to_s.downcase
        value_str = value.to_s.strip
        sources << [key_name, value_str] unless key_name.empty? || value_str.empty?
      end

      sources
    end

    extract_imdb_id = lambda do |row, ids|
      [ids['imdb'], ids[:imdb], row[:imdb_id], row['imdb_id'], row[:external_id], row['external_id']].each do |candidate|
        candidate = candidate.to_s.strip
        return candidate unless candidate.empty?
      end
      ''
    end

    build_imdb_lookup = lambda do
      lookup = Hash.new { |hash, key| hash[key] = {} }
      next lookup unless table_exists?(:calendar_entries)

      self[:calendar_entries].each do |row|
        ids = parse_ids.call(row[:ids])
        imdb_id = extract_imdb_id.call(row, ids)
        next if imdb_id.empty?

        extract_sources.call(row, ids).each do |source, identifier|
          lookup[source][identifier] = imdb_id unless identifier.empty?
        end
      end

      lookup
    end

    resolve_imdb_id = lambda do |row, imdb_lookup|
      source = (row[:external_source] || row['external_source']).to_s.downcase
      identifier = (row[:external_id] || row['external_id']).to_s.strip

      imdb_id = if source == 'imdb' || identifier.match?(/^tt\d+/i)
                  identifier
                else
                  imdb_lookup[source][identifier]
                end

      imdb_id = identifier if imdb_id.to_s.empty? && !identifier.empty?
      imdb_id = File.basename(row[:local_path].to_s) if imdb_id.to_s.empty?
      imdb_id.to_s.strip
    end

    columns = schema(:local_media).map(&:first)
    unless columns.include?(:imdb_id)
      alter_table(:local_media) do
        add_column :imdb_id, String, text: true, null: false, default: ''
      end
    end

    columns = schema(:local_media).map(&:first)
    imdb_lookup = build_imdb_lookup.call

    self[:local_media].each do |row|
      imdb_id = resolve_imdb_id.call(row, imdb_lookup)
      next if imdb_id.empty?

      self[:local_media].where(id: row[:id]).update(imdb_id: imdb_id)
    end

    alter_table(:local_media) do
      drop_column :title if columns.include?(:title)
      drop_column :year if columns.include?(:year)
      drop_column :external_id if columns.include?(:external_id)
      drop_column :external_source if columns.include?(:external_source)
      set_column_default :imdb_id, nil
      add_index [:media_type, :imdb_id], unique: true, name: :idx_local_media_type_imdb_id
    end
  end

  down do
    break unless table_exists?(:local_media)

    alter_table(:local_media) do
      drop_index [:media_type, :imdb_id], name: :idx_local_media_type_imdb_id
      add_column :title, Text, null: false, default: ''
      add_column :year, Integer
      add_column :external_id, Text, null: false, default: ''
      add_column :external_source, Text
      drop_column :imdb_id
    end

    alter_table(:local_media) do
      set_column_default :title, nil
      set_column_default :external_id, nil
      add_index [:media_type, :external_id], unique: true, name: :idx_local_media_type_external_id
    end
  end

end

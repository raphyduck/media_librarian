# frozen_string_literal: true

require 'json'

Sequel.migration do
  up do
    alter_table(:watchlist) do
      add_column :imdb_id, Text, null: false, default: ''
    end

    self[:watchlist].each do |row|
      metadata = row[:metadata]
      parsed_metadata = begin
        JSON.parse(metadata) if metadata.is_a?(String) && metadata.strip.start_with?('{', '[')
      rescue StandardError
        nil
      end

      imdb_id = if parsed_metadata.is_a?(Hash)
                  ids = parsed_metadata['ids'] || parsed_metadata[:ids] || {}
                  ids = ids.is_a?(Hash) ? ids : {}
                  ids['imdb'] || ids[:imdb] || parsed_metadata['imdb_id'] || parsed_metadata['imdbID'] ||
                    parsed_metadata[:imdb_id]
                end
      imdb_id ||= row[:external_id]
      imdb_id = imdb_id.to_s.strip

      self[:watchlist].where(external_id: row[:external_id], type: row[:type]).update(imdb_id: imdb_id)
    end

    alter_table(:watchlist) do
      set_column_default :imdb_id, nil
      drop_index [:external_id, :type], name: :idx_watchlist_external_type
      add_index :imdb_id, unique: true, name: :idx_watchlist_imdb_id
    end
  end

  down do
    alter_table(:watchlist) do
      drop_index :imdb_id, name: :idx_watchlist_imdb_id
      add_index [:external_id, :type], unique: true, name: :idx_watchlist_external_type
      drop_column :imdb_id
    end
  end
end

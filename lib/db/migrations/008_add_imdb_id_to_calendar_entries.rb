# frozen_string_literal: true

require 'json'

Sequel.migration do
  up do
    existing_indexes = indexes(:calendar_entries)

    alter_table(:calendar_entries) do
      add_column :imdb_id, String, size: 50
      drop_index %i[source external_id], name: :idx_calendar_entries_unique if existing_indexes[:idx_calendar_entries_unique]
    end

    self[:calendar_entries].each do |row|
      imdb_id = begin
        ids = JSON.parse(row[:ids].to_s) rescue {}
        id = ids.is_a?(Hash) ? (ids['imdb'] || ids[:imdb]) : nil
        id = ids.values.find { |value| value.to_s.match?(/\Att\d+/i) } if id.to_s.empty? && ids.is_a?(Hash)
        id = row[:external_id] if id.to_s.empty?
        id.to_s.strip
      rescue StandardError
        row[:external_id].to_s
      end

      next if imdb_id.empty?

      self[:calendar_entries].where(id: row[:id]).update(imdb_id: imdb_id)
    end

    alter_table(:calendar_entries) do
      set_column_not_null :imdb_id
      add_index :imdb_id, unique: true, name: :idx_calendar_entries_imdb_id
    end
  end

  down do
    existing_indexes = indexes(:calendar_entries)

    alter_table(:calendar_entries) do
      drop_index :imdb_id, name: :idx_calendar_entries_imdb_id if existing_indexes[:idx_calendar_entries_imdb_id]
      add_index %i[source external_id], unique: true, name: :idx_calendar_entries_unique
      drop_column :imdb_id
    end
  end
end

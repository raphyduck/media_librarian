# frozen_string_literal: true

require 'json'

Sequel.migration do
  up do
    alter_table(:calendar_entries) do
      add_column :imdb_votes, Integer
    end

    self[:calendar_entries].each do |row|
      raw_ids = row[:ids]
      next if raw_ids.to_s.strip.empty?

      votes = begin
        parsed = JSON.parse(raw_ids)
        parsed['imdb_votes'] || parsed['votes']
      rescue StandardError
        nil
      end

      next unless votes

      self[:calendar_entries].where(id: row[:id]).update(imdb_votes: votes.to_i)
    end
  end

  down do
    alter_table(:calendar_entries) do
      drop_column :imdb_votes
    end
  end
end

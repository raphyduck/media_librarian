# frozen_string_literal: true

require 'json'

Sequel.migration do
  change do
    alter_table(:calendar_entries) do
      add_column :ids, :text
    end

    self[:calendar_entries].each do |row|
      source = row[:source].to_s
      external_id = row[:external_id].to_s
      next if source.empty? || external_id.empty?

      ids = JSON.generate({ source => external_id })
      self[:calendar_entries].where(id: row[:id]).update(ids: ids)
    end
  end
end

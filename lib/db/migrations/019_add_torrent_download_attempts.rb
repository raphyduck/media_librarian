# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:torrents) do
      add_column :download_attempts, Integer, default: 0
    end
  end
end

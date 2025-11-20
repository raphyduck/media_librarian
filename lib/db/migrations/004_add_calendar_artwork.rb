# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:calendar_entries) do
      add_column :poster_url, String, size: 500
      add_column :backdrop_url, String, size: 500
    end
  end
end

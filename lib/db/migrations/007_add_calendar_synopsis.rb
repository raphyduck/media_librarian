# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:calendar_entries) do
      add_column :synopsis, :text
    end
  end
end

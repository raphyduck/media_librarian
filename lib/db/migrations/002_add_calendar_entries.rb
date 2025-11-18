# frozen_string_literal: true

Sequel.migration do
  change do
    create_table?(:calendar_entries) do
      primary_key :id
      String :source, size: 50, null: false
      String :external_id, size: 200, null: false
      String :title, size: 500, null: false
      String :media_type, size: 50, null: false
      Text :genres
      Text :languages
      Text :countries
      Float :rating
      Date :release_date
      DateTime :created_at
      DateTime :updated_at

      index %i[source external_id], unique: true, name: :idx_calendar_entries_unique
      index :release_date, name: :idx_calendar_entries_release_date
    end
  end
end

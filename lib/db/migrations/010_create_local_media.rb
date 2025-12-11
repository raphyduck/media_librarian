# frozen_string_literal: true

Sequel.migration do
  change do
    create_table?(:local_media) do
      primary_key :id
      Text :media_type, null: false
      Text :title, null: false
      Integer :year
      Text :external_id, null: false
      Text :external_source
      Text :local_path, null: false
      DateTime :created_at

      index [:media_type, :external_id], unique: true, name: :idx_local_media_type_external_id
    end
  end
end

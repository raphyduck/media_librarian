# frozen_string_literal: true

Sequel.migration do
  change do
    create_table?(:watchlist) do
      Text :external_id, null: false
      Text :type, null: false
      Text :title, null: false
      Text :metadata
      DateTime :created_at
      DateTime :updated_at

      index [:external_id, :type], unique: true, name: :idx_watchlist_external_type
    end
  end
end

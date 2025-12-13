# frozen_string_literal: true

Sequel.migration do
  up do
    table_columns = schema(:watchlist).map(&:first)
    existing_indexes = indexes(:watchlist)

    alter_table(:watchlist) do
      drop_index :imdb_id, name: :idx_watchlist_imdb_id if existing_indexes[:idx_watchlist_imdb_id]
      drop_column :external_id if table_columns.include?(:external_id)
      drop_column :title if table_columns.include?(:title)
      drop_column :metadata if table_columns.include?(:metadata)
      add_index %i[imdb_id type], unique: true, name: :idx_watchlist_imdb_type
    end
  end

  down do
    table_columns = schema(:watchlist).map(&:first)
    existing_indexes = indexes(:watchlist)

    alter_table(:watchlist) do
      drop_index %i[imdb_id type], name: :idx_watchlist_imdb_type if existing_indexes[:idx_watchlist_imdb_type]
      add_column :external_id, :text, null: false, default: '' unless table_columns.include?(:external_id)
      add_column :title, :text, null: false, default: '' unless table_columns.include?(:title)
      add_column :metadata, :text unless table_columns.include?(:metadata)
      add_index :imdb_id, unique: true, name: :idx_watchlist_imdb_id unless existing_indexes[:idx_watchlist_imdb_id]
    end

    run <<~SQL
      UPDATE watchlist
      SET external_id = COALESCE(imdb_id, ''), title = COALESCE(title, imdb_id)
      WHERE external_id IS NULL OR title IS NULL OR external_id = '' OR title = '';
    SQL
  end
end

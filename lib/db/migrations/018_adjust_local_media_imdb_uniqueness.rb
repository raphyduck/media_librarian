# frozen_string_literal: true

Sequel.migration do
  up do
    break unless table_exists?(:local_media)

    alter_table(:local_media) do
      set_column_allow_null :imdb_id
      set_column_default :imdb_id, nil
    end

    self[:local_media].where(imdb_id: '').update(imdb_id: nil)
  end

  down do
    break unless table_exists?(:local_media)

    self[:local_media].where(imdb_id: nil).update(imdb_id: '')

    alter_table(:local_media) do
      set_column_allow_null :imdb_id, false
      set_column_default :imdb_id, ''
    end
  end
end

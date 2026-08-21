# frozen_string_literal: true

# A title legitimately owns several files: a movie split across parts or kept in
# more than one quality, and every single episode of a show. The unique index on
# (media_type, imdb_id) combined with the INSERT OR REPLACE the scanner uses made
# each newly scanned file silently evict the previously stored one, so
# local_media only ever kept the last file seen for a title — the collection lost
# the extra movie files and the whole season/episode hierarchy of every show.
#
# The file path is the real identity of a local_media row, so uniqueness moves
# there and (media_type, imdb_id) is demoted to a plain lookup index.
Sequel.migration do
  up do
    break unless table_exists?(:local_media)

    duplicates = self[:local_media]
                 .select { [media_type, local_path, Sequel.function(:min, :id).as(:keep_id)] }
                 .group(:media_type, :local_path)
                 .having { count.function.* > 1 }
                 .all

    duplicates.each do |row|
      self[:local_media]
        .where(media_type: row[:media_type], local_path: row[:local_path])
        .exclude(id: row[:keep_id])
        .delete
    end

    alter_table(:local_media) do
      drop_index [:media_type, :imdb_id], name: :idx_local_media_type_imdb_id
      add_index [:media_type, :local_path], unique: true, name: :idx_local_media_type_local_path
      add_index [:media_type, :imdb_id], name: :idx_local_media_type_imdb_id_lookup
    end
  end

  down do
    break unless table_exists?(:local_media)

    duplicates = self[:local_media]
                 .select { [media_type, imdb_id, Sequel.function(:min, :id).as(:keep_id)] }
                 .exclude(imdb_id: nil)
                 .group(:media_type, :imdb_id)
                 .having { count.function.* > 1 }
                 .all

    duplicates.each do |row|
      self[:local_media]
        .where(media_type: row[:media_type], imdb_id: row[:imdb_id])
        .exclude(id: row[:keep_id])
        .delete
    end

    alter_table(:local_media) do
      drop_index [:media_type, :imdb_id], name: :idx_local_media_type_imdb_id_lookup
      drop_index [:media_type, :local_path], name: :idx_local_media_type_local_path
      add_index [:media_type, :imdb_id], unique: true, name: :idx_local_media_type_imdb_id
    end
  end
end

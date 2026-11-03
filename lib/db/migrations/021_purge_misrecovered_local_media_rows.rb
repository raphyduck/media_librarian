# frozen_string_literal: true

# scripts/repair_db.sh rebuilds a damaged database with SQLite's `.recover`,
# which reassigns orphaned b-tree pages to whatever table it can. After the
# July 2026 repair, calendar_entries row 81359 (source, external_id, title,
# media_type) landed in local_media as (media_type='trakt',
# local_path='fall-to-pieces-2025', created_at='Fall To Pieces',
# imdb_id='movie'). The unparseable created_at made every SELECT of the table
# raise, so the collection came back empty for months.
#
# local_media only ever holds 'movie' and 'show' rows (the scan writes them
# through Utils.canonical_media_type), so any other media_type is such an
# artefact and is dropped.
Sequel.migration do
  up do
    break unless table_exists?(:local_media)

    self[:local_media].exclude(media_type: %w[movie show]).delete
  end

  down do
    # Irreversible: the dropped rows were never valid local media.
  end
end

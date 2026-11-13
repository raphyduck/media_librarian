# frozen_string_literal: true

# movie_lookup rows (metadata_search.type = 2) written before the resolver
# fixes (media_chose_best, blank imdb ids, alt-title rows) could hold a wrong
# resolution that the 120-day TTL kept serving, so watchlist movies never
# matched their releases. Drop them once; they are rebuilt on demand.
Sequel.migration do
  up do
    break unless table_exists?(:metadata_search)

    self[:metadata_search].where(type: 2).delete
  end

  down do
    # Irreversible: a cache, rebuilt on demand.
  end
end

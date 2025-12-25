# frozen_string_literal: true

require 'json'

Sequel.migration do
  up do
    return unless table_exists?(:media_lists)

    if table_exists?(:watchlist)
      watchlist = self[:watchlist]
      watchlist_columns = schema(:watchlist).map(&:first)
      now = Time.now.utc

      self[:media_lists].each do |row|
        imdb_id = (row[:imdb] || row[:external_id]).to_s.strip
        next if imdb_id.empty?

        type = row[:type].to_s.strip
        type = 'movies' if type.empty?
        title = row[:title].to_s.strip
        metadata = {
          list_name: row[:list_name],
          year: row[:year],
          alt_titles: row[:alt_titles],
          url: row[:url],
          tmdb: row[:tmdb]
        }
        metadata[:title] = title unless title.empty?
        metadata.compact!

        data = { imdb_id: imdb_id, type: type }
        data[:title] = title if watchlist_columns.include?(:title) && !title.empty?
        data[:metadata] = JSON.generate(metadata) if watchlist_columns.include?(:metadata) && !metadata.empty?
        data[:created_at] = row[:created_at] || now if watchlist_columns.include?(:created_at)
        data[:updated_at] = now if watchlist_columns.include?(:updated_at)

        conflict_keys = watchlist_columns.include?(:type) ? { imdb_id: imdb_id, type: type } : { imdb_id: imdb_id }

        if watchlist.respond_to?(:insert_conflict)
          watchlist.insert_conflict(target: conflict_keys.keys, update: data).insert(data)
        else
          begin
            watchlist.insert(data)
          rescue Sequel::UniqueConstraintViolation
            watchlist.where(conflict_keys).update(data)
          end
        end
      end
    end

    drop_table?(:media_lists)
  end

  down do
    create_table?(:media_lists) do
      Text :list_name, null: false
      Text :type
      Text :title
      Integer :year
      Text :alt_titles
      Text :url
      Text :imdb
      Text :tmdb
      DateTime :created_at

      index [:list_name, :title, :year, :imdb], unique: true, name: :idx_media_lists_unique
    end
  end
end

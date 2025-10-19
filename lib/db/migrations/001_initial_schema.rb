# frozen_string_literal: true

Sequel.migration do
  change do
    create_table?(:queues_state) do
      String :queue_name, size: 200, primary_key: true
      Text :value
      DateTime :created_at
    end

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

    create_table?(:metadata_search) do
      Text :keywords, null: false
      Integer :type
      Text :result
      DateTime :created_at

      index [:keywords, :type], unique: true, name: :idx_metadata_search_keywords_type
    end

    create_table?(:torrents) do
      String :name, size: 500, primary_key: true
      Text :identifier
      Text :identifiers
      Text :tattributes
      DateTime :created_at
      DateTime :updated_at
      DateTime :waiting_until
      Text :torrent_id
      Integer :status

      index :torrent_id, unique: true, name: :idx_torrents_torrent_id
    end

    create_table?(:trakt_auth) do
      String :account, size: 30, primary_key: true
      String :access_token, size: 200
      String :token_type, size: 200
      String :refresh_token, size: 200
      String :scope, size: 200
      Integer :created_at
      Integer :expires_in
    end
  end
end

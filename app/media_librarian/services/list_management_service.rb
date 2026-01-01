# frozen_string_literal: true

require_relative '../../local_media_repository'

module MediaLibrarian
  module Services
    class CustomListRequest
      attr_reader :name, :description, :origin, :criteria, :no_prompt

      def initialize(name:, description:, origin: 'collection', criteria: {}, no_prompt: 0)
        @name = name
        @description = description
        @origin = origin
        @criteria = criteria
        @no_prompt = no_prompt
      end
    end

    class SearchListRequest
      attr_reader :source_type, :category, :source, :no_prompt

      def initialize(source_type:, category:, source:, no_prompt: 0)
        @source_type = source_type
        @category = category
        @source = source
        @no_prompt = no_prompt
      end
    end

    class ListManagementService < BaseService
      def create_custom_list(request)
        speaker.speak_up('Trakt list management has been retired; skipping custom list creation.', 0)
      end

      def get_search_list(request)
        existing_files_from_db = media_repository.library_index(type: request.category)
        if request.source_type == 'local_files' && existing_files_from_db.empty?
          speaker.speak_up("get_search_list: no existing media in DB for category=#{request.category}, returning empty", 0) if speaker
          return [{ request.category => {} }, {}]
        end
        search_list = {}
        existing_files = {}
        cache_name = "#{request.source_type}#{request.category}"
        Utils.lock_block(__method__.to_s + cache_name) do
          search_list, existing_files = build_search_list(request, cache_name, existing_files_from_db)
        end
        result_list = (search_list[cache_name] || {}).deep_dup
        result_list[:calendar_entries] = search_list[:calendar_entries].deep_dup if search_list[:calendar_entries]
        [existing_files.deep_dup, result_list]
      end

      private
      def build_search_list(request, cache_name, existing_files_from_db)
        search_list = {}
        existing_files = {}
        case request.source_type
        when 'local_files'
          search_list[cache_name] = existing_files_from_db
          existing_files[request.category] = search_list[cache_name].dup
        when 'watchlist', 'download_list', 'lists'
          rows = WatchlistStore.fetch_with_details(type: request.category)
          calendar_entries = []
          rows.each do |row|
            ids = normalize_metadata(row[:ids] || row['ids'])
            imdb_id = imdb_identifier(row, ids)
            next if imdb_id.to_s.empty?
            ids = ids.transform_keys { |k| k.is_a?(String) ? k : k.to_s }
            ids['imdb'] = imdb_id if imdb_id
            attrs = { already_followed: 1, watchlist: 1, imdb_id: imdb_id }
            year = row[:year] || row['year']
            title = build_watchlist_title(row[:title] || row['title'], year)
            search_list[cache_name] = Library.parse_media({ type: 'lists', name: title }, request.category, request.no_prompt, search_list[cache_name] || {}, {}, {}, attrs, '', ids)
            calendar_entries << build_calendar_entry(row, ids, imdb_id, request.category)
          end
          search_list[:calendar_entries] = calendar_entries unless calendar_entries.empty?
        end
        existing_files[request.category] ||= existing_files_from_db
        existing_files[request.category][:shows] = search_list[cache_name][:shows] if search_list[cache_name]&.dig(:shows) && request.category.to_s == 'shows'
        annotate_calendar_downloads(search_list, existing_files, request.category)
        [search_list, existing_files]
      end

      def annotate_calendar_downloads(search_list, existing_files, category)
        entries = search_list[:calendar_entries]
        return unless entries.is_a?(Array) && !entries.empty?

        library = existing_files[category] || {}
        entries.each do |entry|
          identifier = imdb_identifier(entry, entry[:ids] || entry['ids'])
          entry[:downloaded] = Metadata.media_exist?(library, identifier)
        end
      end

      def build_calendar_entry(entry, ids, imdb_id, type)
        release_date = entry[:release_date] || entry['release_date']

        {
          ids: ids,
          imdb_id: imdb_id,
          type: type,
          release_date: release_date,
          title: entry[:title] || entry['title']
        }
      end

      def build_watchlist_title(title, year)
        return title.to_s if year.to_i <= 0

        "#{title} (#{year})"
      end

      def normalize_metadata(metadata)
        metadata.is_a?(Hash) ? metadata : {}
      end

      def imdb_identifier(source, ids = nil)
        ids ||= source[:ids] || source['ids'] if source.is_a?(Hash)
        ids = ids.is_a?(Hash) ? ids.transform_keys(&:to_s) : {}

        [
          (source[:imdb_id] if source.is_a?(Hash)),
          (source['imdb_id'] if source.is_a?(Hash)),
          ids['imdb'],
        ].compact.map(&:to_s).map(&:strip).find { |value| !value.empty? }
      end

      def media_repository
        @media_repository ||= LocalMediaRepository.new(app: app)
      end

    end
  end
end

# frozen_string_literal: true

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
        unless request.source.is_a?(Hash) && request.source['existing_folder'] && request.source['existing_folder'][request.category]
          speaker.speak_up("get_search_list: empty/invalid source for category=#{request.category}, returning empty", 0) if speaker
          return [{ request.category => {} }, {}]
        end
        return [{}, {}] unless request.source['existing_folder'][request.category]

        search_list = {}
        existing_files = {}
        cache_name = "#{request.source_type}#{request.category}#{request.source['existing_folder'][request.category]}#{request.source['list_name']}"
        Utils.lock_block(__method__.to_s + cache_name) do
          search_list, existing_files = build_search_list(request, cache_name)
        end
        result_list = (search_list[cache_name] || {}).deep_dup
        result_list[:calendar_entries] = search_list[:calendar_entries].deep_dup if search_list[:calendar_entries]
        [existing_files.deep_dup, result_list]
      end

      private
      def build_search_list(request, cache_name)
        search_list = {}
        existing_files = {}
        case request.source_type
        when 'filesystem'
          search_list[cache_name] = Library.process_folder(type: request.category, folder: request.source['existing_folder'][request.category], no_prompt: request.no_prompt, filter_criteria: request.source['filter_criteria'], item_name: request.source['item_name'])
          existing_files[request.category] = search_list[cache_name].dup
        when 'download_list'
          rows = WatchlistStore.fetch(type: request.category)
          calendar_entries = []
          rows.each do |row|
            meta = normalize_metadata(row[:metadata])
            ids = meta[:ids] || {}
            attrs = { already_followed: 1, watchlist: 1, external_id: row[:external_id] }
            attrs[:metadata] = meta unless meta.empty?
            title = build_watchlist_title(row[:title], meta[:year])
            search_list[cache_name] = Library.parse_media({ type: 'lists', name: title }, request.category, request.no_prompt, search_list[cache_name] || {}, {}, {}, attrs, '', ids)
            calendar_entries.concat(build_calendar_entries(meta[:calendar_entries], ids, row[:external_id], request.category))
          end
          search_list[:calendar_entries] = calendar_entries unless calendar_entries.empty?
        when 'lists'
          speaker.speak_up("Parsing search list '#{request.source['list_name']}', can take a long time...", 0)
          list_name = (request.source['list_name'] || 'default').to_s
          entries = ListStore.fetch_list(list_name)
          entries.each do |row|
            ttype = ('movies'.include?(row[:type]) ? 'movies' : row[:type]) || 'movies'
            key = row[:title].to_s + row[:year].to_s + ttype.to_s
            next if key.empty?

            search_list[cache_name] = Library.parse_media({ type: 'lists', name: "#{row[:title]} (#{row[:year]})".gsub('/', ' ') }, ttype, request.no_prompt, search_list[cache_name] || {}, {}, {}, { obj_title: row[:title], obj_year: row[:year], obj_url: row[:url], obj_type: ttype }, '', { 'tmdb' => row[:tmdb], 'imdb' => row[:imdb] })
          end
        end
        existing_files[request.category] = Library.process_folder(type: request.category, folder: request.source['existing_folder'][request.category], no_prompt: request.no_prompt, remove_duplicates: 0)
        existing_files[request.category][:shows] = search_list[cache_name][:shows] if search_list[cache_name]&.dig(:shows) && request.category.to_s == 'shows'
        annotate_calendar_downloads(search_list, existing_files, request.category)
        [search_list, existing_files]
      end

      def annotate_calendar_downloads(search_list, existing_files, category)
        entries = search_list[:calendar_entries]
        return unless entries.is_a?(Array) && !entries.empty?

        library = existing_files[category] || {}
        entries.each do |entry|
          identifiers = [entry[:external_id], entry['external_id']].compact
          ids = entry[:ids] || entry['ids']
          identifiers.concat(ids.values.compact) if ids.is_a?(Hash)
          entry[:downloaded] = identifiers.any? { |id| Metadata.media_exist?(library, id) }
        end
      end

      def build_calendar_entries(raw_entries, ids, external_id, type)
        return [] unless raw_entries.is_a?(Array)

        raw_entries.filter_map do |entry|
          next unless entry

          base = entry.is_a?(Hash) ? entry.transform_keys(&:to_sym) : { title: entry }
          base.merge(ids: ids, external_id: external_id, type: type)
        end
      end

      def build_watchlist_title(title, year)
        return title.to_s if year.to_i <= 0

        "#{title} (#{year})"
      end

      def normalize_metadata(metadata)
        metadata.is_a?(Hash) ? metadata : {}
      end

    end
  end
end

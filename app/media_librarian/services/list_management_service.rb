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

    class MediaListSizeRequest
      attr_reader :list, :folder, :type_filter

      def initialize(list: [], folder: {}, type_filter: '')
        @list = list
        @folder = folder
        @type_filter = type_filter
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
        speaker.speak_up("Fetching items from #{request.origin}...", 0)
        new_list = {
          'movies' => TraktAgent.list(request.origin, 'movies'),
          'shows' => TraktAgent.list(request.origin, 'shows')
        }
        dest_list = TraktAgent.list('lists').find { |list| list['name'] == request.name }
        to_delete = {}
        if dest_list
          speaker.speak_up("List #{request.name} exists", 0)
          to_delete = TraktAgent.parse_custom_list(TraktAgent.list(request.name))
        else
          speaker.speak_up("List #{request.name} doesn't exist, creating it...")
          TraktAgent.create_list(request.name, request.description)
        end
        speaker.speak_up("Ok, we have added #{(new_list['movies'].length + new_list['shows'].length)} items from #{request.origin}, let's chose what to include in the new list #{request.name}.", 0)
        %w[movies shows].each do |type|
          apply_list_criteria(request, type, new_list, to_delete)
        end
        speaker.speak_up("List #{request.name} is up to date!", 0)
      end

      def get_media_list_size(request)
        list = request.list
        folder = request.folder
        type_filter = request.type_filter
        if list.nil? || list.empty?
          list_name = speaker.ask_if_needed('Please enter the name of the trakt list you want to know the total disk size of (of medias on your set folder): ')
          list = TraktAgent.list(list_name, '')
        end
        parsed_media = {}
        list_size = 0
        list_paths = []
        list.each do |item|
          type = item['type'] == 'season' ? 'show' : item['type']
          resource_type = item['type']
          next unless %w[movie show].include?(type)
          list_type = type[-1] == 's' ? type : "#{type}s"
          next if type_filter && type_filter != '' && type_filter != list_type
          parsed_media[list_type] ||= {}
          folder[list_type] ||= speaker.ask_if_needed("Enter the path of the folder where your #{type}s media are stored: ")
          title = "#{item[type]['title']}#{' (' + item[type]['year'].to_s + ')' if list_type == 'movies' && item[type]['year'].to_i > 0}"
          next if parsed_media[list_type][title] && resource_type != 'season'
          folders = file_system.search_folder(folder[list_type], { 'regex' => StringUtils.title_match_string(title), 'maxdepth' => (type == 'show' ? 1 : nil), 'includedir' => 1, 'return_first' => 1 })
          file = folders.first
          if file
            if resource_type == 'season'
              season = item[resource_type]['number'].to_s
              season_file = file_system.search_folder(file[0], { 'regex' => "season.#{season}", 'maxdepth' => 1, 'includedir' => 1, 'return_first' => 1 }).first
              if season_file
                list_size += FileUtils.get_disk_size(season_file[0]).to_d
                list_paths << season_file[0]
              end
            else
              list_size += FileUtils.get_disk_size(file[0]).to_d
              list_paths << file[0]
            end
          else
            speaker.speak_up("#{title} NOT FOUND in #{folder[list_type]}")
          end
          parsed_media[list_type][title] = item[type]
        end
        speaker.speak_up("The total disk size of this list is #{(list_size / 1024 / 1024 / 1024).round(2)} GB")
        [list_size, list_paths]
      rescue StandardError => e
        speaker.tell_error(e, Utils.arguments_dump(binding))
        [0, []]
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

      def apply_list_criteria(request, type, new_list, to_delete)
        criteria = request.criteria[type] || {}
        if (criteria['noadd'] && criteria['noadd'].to_i > 0) || speaker.ask_if_needed("Do you want to add #{type} items? (y/n)", request.no_prompt, 'y') != 'y'
          new_list.delete(type)
          new_list[type] = to_delete[type] if criteria['add_only'].to_i > 0 && to_delete && to_delete[type]
          return
        end
        folder = speaker.ask_if_needed("What is the path of your folder where #{type} are stored? (in full)", criteria['folder'].nil? ? 0 : 1, criteria['folder'])
        %w[released_before released_after days_older days_newer entirely_watched partially_watched ended not_ended watched canceled].each do |criterion|
          value = speaker.ask_if_needed("Enter the value to keep only #{type} #{criterion.gsub('_', ' ')}: (empty to not use this filter)", request.no_prompt, criteria[criterion])
          next if value.to_s == ''

          new_list[type] = TraktAgent.filter_trakt_list(new_list[type], type, criterion, criteria['include'], criteria['add_only'], to_delete[type], value, folder)
        end
        review_items(request, type, new_list, to_delete, criteria, folder)
        new_list[type].map! do |item|
          item[type[0...-1]]['seasons'] = item['seasons'].map { |season| season.reject { |key, _| key == 'episodes' } } if item['seasons']
          item[type[0...-1]]
        end
        speaker.speak_up('Updating items in the list...', 0)
        TraktAgent.remove_from_list(to_delete[type], request.name, type) unless to_delete.nil? || to_delete.empty? || to_delete[type].nil? || to_delete[type].empty? || criteria['add_only'].to_i > 0
        TraktAgent.add_to_list(new_list[type], request.name, type)
      end

      def review_items(request, type, new_list, to_delete, criteria, folder)
        return unless criteria['review'] || speaker.ask_if_needed("Do you want to review #{type} individually? (y/n)", request.no_prompt, 'n') == 'y'

        review_criteria = criteria['review'] || {}
        speaker.speak_up('Preparing list of files to review...', 0)
        new_list[type].reverse_each do |item|
          title = item[type[0...-1]]['title']
          year = item[type[0...-1]]['year']
          title = "#{title} (#{year})" if year.to_i > 0 && type == 'movies'
          folders = file_system.search_folder(folder, { 'regex' => StringUtils.title_match_string(title), 'maxdepth' => (type == 'shows' ? 1 : nil), 'includedir' => 1, 'return_first' => 1 })
          file = folders.first
          size = file ? FileUtils.get_disk_size(file[0]) : -1
          if size.to_d < 0 && (review_criteria['remove_deleted'].to_i > 0 || speaker.ask_if_needed("No folder found for #{title}, do you want to delete the item from the list? (y/n)", request.no_prompt, 'n') == 'y')
            speaker.speak_up "No folder found for '#{title}', removing from list" if Env.debug?
            new_list[type].delete(item)
            next
          end
          base_condition = criteria['add_only'].to_i.zero? || !TraktAgent.search_list(type[0...-1], item, to_delete[type])
          inclusion_condition = criteria['include'].nil? || !criteria['include'].include?(title)
          decision = speaker.ask_if_needed(
            "Do you want to add #{type} '#{title}' (disk size #{[(size.to_d / 1024 / 1024 / 1024).round(2), 0].max} GB) to the list (y/n)",
            review_criteria['add_all'].to_i,
            'y'
          )
          unless base_condition && inclusion_condition && decision.to_s == 'y'
            speaker.speak_up "Removing '#{title}' from list" if Env.debug?
            new_list[type].delete(item)
            next
          end
          handle_show_seasons(type, item, review_criteria)
          print '.'
        end
      end

      def handle_show_seasons(type, item, review_criteria)
        return unless type == 'shows'
        return unless (review_criteria['add_all'].to_i == 0 || review_criteria['no_season'].to_i > 0) && ((review_criteria['add_all'].to_i == 0 && review_criteria['no_season'].to_i > 0) || speaker.ask_if_needed("Do you want to keep all seasons of #{item['show']['title']}? (y/n)", 0, 'n') != 'y')

        choice = speaker.ask_if_needed("Which seasons do you want to keep? (separated by comma, like this: '1,2,3', empty for none", 0, '').to_s.split(',')
        if choice.empty?
          item['seasons'] = nil
        else
          item['seasons'].select! { |season| choice.map! { |n| n.to_i }.include?(season['number']) }
        end
      end

      def build_search_list(request, cache_name)
        search_list = {}
        existing_files = {}
        watchlist_entries = []
        case request.source_type
        when 'filesystem'
          search_list[cache_name] = Library.process_folder(type: request.category, folder: request.source['existing_folder'][request.category], no_prompt: request.no_prompt, filter_criteria: request.source['filter_criteria'], item_name: request.source['item_name'])
          existing_files[request.category] = search_list[cache_name].dup
        when 'trakt'
          speaker.speak_up("Parsing trakt list '#{request.source['list_name']}', can take a long time...", 0)
          TraktAgent.list(request.source['list_name']).each do |item|
            type = item['type'] rescue next
            trakt_object = item[type]
            type = Utils.regularise_media_type(type)
            next unless type == request.category
            next if Time.now.year < (trakt_object['year'] || Time.now.year + 3)

            search_list[cache_name] = Library.parse_media({ type: 'trakt', name: "#{trakt_object['title']} (#{trakt_object['year']})".gsub('/', ' ') }, type, request.no_prompt, search_list[cache_name] || {}, {}, {}, { trakt_obj: trakt_object, trakt_list: request.source['list_name'], trakt_type: type }, '', trakt_object['ids'])
            watchlist_entries << build_watchlist_entry(trakt_object, type) if watchlist_target?(request)
          end
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
        persist_watchlist(watchlist_entries)
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

      def watchlist_target?(request)
        request.source_type == 'trakt' && request.source['list_name'].to_s == 'watchlist'
      end

      def build_watchlist_entry(trakt_object, type)
        ids = trakt_object['ids'] || {}
        external_id = ids['trakt'] || ids['tmdb'] || ids['imdb'] || trakt_object['title']
        return unless external_id

        {
          external_id: external_id,
          type: type,
          title: trakt_object['title'],
          metadata: { year: trakt_object['year'], ids: ids }
        }
      end

      def build_watchlist_title(title, year)
        return title.to_s if year.to_i <= 0

        "#{title} (#{year})"
      end

      def normalize_metadata(metadata)
        metadata.is_a?(Hash) ? metadata : {}
      end

      def persist_watchlist(entries)
        filtered = entries.compact
        WatchlistStore.upsert(filtered) unless filtered.empty?
      end
    end
  end
end

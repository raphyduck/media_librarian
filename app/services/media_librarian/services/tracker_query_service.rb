# frozen_string_literal: true

module MediaLibrarian
  module Services
    class TrackerSearchRequest
      attr_reader :sources, :keyword, :limit, :category, :qualities,
                  :filter_dead, :url, :sort_by, :filter_out, :strict,
                  :download_criteria, :post_actions, :search_category

      def initialize(sources:, keyword:, limit: 50, category:,
                     qualities: {}, filter_dead: 1, url: nil,
                     sort_by: [:tracker, :seeders], filter_out: [],
                     strict: 0, download_criteria: {}, post_actions: {},
                     search_category: nil)
        @sources = sources
        @keyword = keyword
        @limit = limit
        @category = category
        @qualities = qualities
        @filter_dead = filter_dead
        @url = url
        @sort_by = sort_by
        @filter_out = filter_out
        @strict = strict
        @download_criteria = download_criteria
        @post_actions = post_actions
        @search_category = search_category
      end
    end

    class TrackerQueryService < BaseService
      def get_results(request)
        tries ||= 3
        results = []
        r = {}
        search_category = request.search_category.to_s == '' ? request.category : request.search_category
        keyword = request.keyword.dup
        keyword.gsub!(/[\(\)\:]/, '')
        trackers = get_trackers(request.sources)
        timeframe_trackers = parse_tracker_timeframes(request.sources || {})
        trackers.each do |tracker|
          speaker.speak_up("Looking for all torrents in category '#{search_category}' on '#{tracker}'") if keyword.to_s == '' && Env.debug?
          keyword_with_site = (keyword + get_site_keywords(tracker, search_category)).strip
          tracker_results = launch_search(tracker, search_category, keyword_with_site)
          tracker_results = launch_search(tracker, search_category, keyword) if keyword_with_site != keyword && (tracker_results.nil? || tracker_results.empty?)
          results += tracker_results
        end
        request.filter_out.each do |filter_key|
          filter_results(results, filter_key, 1) { |torrent| torrent[filter_key.to_sym].to_i != 0 }
        end
        if request.filter_dead.to_i > 0
          filter_results(results, 'seeders', request.filter_dead) { |torrent| torrent[:seeders].to_i >= request.filter_dead.to_i }
        end
        results.sort_by! { |torrent| request.sort_by.map { |field| field == :tracker ? trackers.index(torrent[field]) : -torrent[field].to_i } }
        unless request.qualities.nil? || request.qualities.empty?
          filter_results(results, 'size', "between #{request.qualities['min_size']}MB and #{request.qualities['max_size']}MB") do |torrent|
            file_type = TvSeries.identify_file_type(torrent[:name])
            (request.category == 'shows' && (file_type == 'season' || file_type == 'series')) ||
              ((torrent[:size].to_f == 0 || request.qualities['min_size'].to_f == 0 || torrent[:size].to_f >= request.qualities['min_size'].to_f * 1024 * 1024) &&
               (torrent[:size].to_f == 0 || request.qualities['max_size'].to_f == 0 || torrent[:size].to_f <= request.qualities['max_size'].to_f * 1024 * 1024))
          end
          if request.qualities['timeframe_size'].to_s != '' && (request.qualities['max_size'].to_s != '' || request.qualities['target_size'].to_s != '')
            results.map! do |torrent|
              if torrent[:size].to_f < (request.qualities['target_size'] || request.qualities['max_size']).to_f * 1024 * 1024
                torrent[:timeframe_size] = Utils.timeperiod_to_sec(request.qualities['timeframe_size'].to_s).to_i
              end
              torrent
            end
          end
        end
        unless timeframe_trackers.nil?
          results.map! do |torrent|
            torrent[:timeframe_tracker] = Utils.timeperiod_to_sec(timeframe_trackers[torrent[:tracker]].to_s).to_i
            torrent
          end
        end
        results = results.first(request.limit.to_i) if request.limit.to_i > 0
        download_criteria = prepare_download_criteria(request.download_criteria, request.category, request.post_actions)
        results.each do |torrent|
          torrent[:assume_quality] = TorrentSearch.get_tracker_config(torrent[:tracker])['assume_quality'].to_s + ' ' + request.qualities['assume_quality'].to_s
          _, accept = Quality.filter_quality(torrent[:name], request.qualities, request.post_actions[:language], torrent[:assume_quality], request.category)
          r = Library.parse_media({ type: 'torrent' }.merge(torrent), request.category, request.strict, r, {}, {}, download_criteria) if accept
        end
        r
      rescue StandardError => e
        speaker.tell_error(e, Utils.arguments_dump(binding))
        retry unless (tries -= 1) <= 0
        {}
      end

      def get_trackers(sources)
        trackers = parse_tracker_sources(sources || [])
        trackers = app.trackers.map { |tracker_name, _| tracker_name } if trackers.empty?
        trackers
      end

      def get_site_keywords(type, category = '')
        category && category != '' && app.config[type] && app.config[type]['site_specific_kw'] && app.config[type]['site_specific_kw'][category] ? " #{app.config[type]['site_specific_kw'][category]}" : ''
      end

      def get_torrent_file(did, url, destination_folder = app.temp_dir)
        return did if Env.pretend?
        path = "#{destination_folder}/#{did}.torrent"
        FileUtils.rm(path) if File.exist?(path)
        url = @base_url + '/' + url if url.start_with?('/')
        begin
          tries ||= 3
          app.mechanizer.get(url).save(path)
        rescue StandardError => e
          if (tries -= 1) >= 0
            sleep 1
            retry
          else
            raise e
          end
        end
        path
      rescue StandardError => e
        speaker.tell_error(e, Utils.arguments_dump(binding))
        nil
      end

      def launch_search(tracker, search_category, keyword)
        if app.trackers[tracker]
          app.trackers[tracker].search(search_category, keyword)
        else
          TorrentRss.links(tracker)
        end
      end

      def parse_tracker_sources(sources)
        case sources
        when String
          [sources]
        when Hash
          sources.map do |tracker, nested|
            if tracker == 'rss'
              parse_tracker_sources(nested)
            else
              tracker
            end
          end
        when Array
          sources.map do |source|
            parse_tracker_sources(source)
          end
        end.flatten
      end

      def parse_tracker_timeframes(sources, timeframe_trackers = {}, tracker_key = '')
        if sources.is_a?(Hash)
          sources.each do |key, value|
            if key == 'timeframe' && tracker_key.to_s != ''
              timeframe_trackers.merge!({ tracker_key => value })
            elsif value.is_a?(Hash) || value.is_a?(Array)
              timeframe_trackers = parse_tracker_timeframes(value, timeframe_trackers, key)
            end
          end
        elsif sources.is_a?(Array)
          sources.each do |value|
            timeframe_trackers = parse_tracker_timeframes(value, timeframe_trackers, tracker_key)
          end
        end
        timeframe_trackers
      end

      private

      def filter_results(results, condition_name, required_value)
        results.select! do |torrent|
          if Env.debug? && !yield(torrent)
            speaker.speak_up "Torrent '#{torrent[:name]}'[#{condition_name}] do not match requirements (required #{required_value}), removing from list"
          end
          yield(torrent)
        end
      end

      def prepare_download_criteria(download_criteria, category, post_actions)
        return {} if download_criteria.nil? || download_criteria.empty?

        download_criteria = Utils.recursive_typify_keys(download_criteria)
        download_criteria[:move_completed] = download_criteria[:destination][category.to_sym] if download_criteria[:destination]
        download_criteria.delete(:destination)
        begin
          download_criteria[:whitelisted_extensions] = download_criteria[:whitelisted_extensions][Metadata.media_type_get(category)]
        rescue StandardError
          nil
        end
        download_criteria[:whitelisted_extensions] = FileUtils.get_valid_extensions(category) unless download_criteria[:whitelisted_extensions].is_a?(Array)
        download_criteria.merge(post_actions)
      end
    end
  end
end

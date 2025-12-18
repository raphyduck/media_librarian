# frozen_string_literal: true

require 'yaml'

require_relative 'tracker_login_service'

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
      LoginRequiredError = Class.new(StandardError)

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

      def get_torrent_file(did, url, destination_folder = app.temp_dir, tracker: nil)
        return did if Env.pretend?
        path = "#{destination_folder}/#{did}.torrent"
        FileUtils.rm(path) if File.exist?(path)
        url = @base_url + '/' + url if url.start_with?('/')
        metadata = tracker_login_metadata(tracker)
        agent = metadata ? tracker_login_service.ensure_session(tracker) : app.mechanizer
        retried_login = false
        begin
          tries ||= 3
          page = agent.get(url)
          raise LoginRequiredError if metadata && login_redirect?(page, metadata)
          page.save(path)
        rescue StandardError => e
          if metadata && !retried_login && login_retryable?(e)
            agent = tracker_login_service.login(tracker)
            retried_login = true
            retry
          elsif (tries -= 1) >= 0
            sleep 1 unless metadata && login_retryable?(e)
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
          TorrentRss.links(tracker, tracker: rss_tracker_identifier(tracker))
        end
      end

      def parse_tracker_sources(sources, rss_tracker_lookup = nil, rss_context: false)
        rss_tracker_lookup ||= begin
          @rss_tracker_lookup = {}
        end

        case sources
        when String
          [sources]
        when Hash
          if rss_context && rss_hash_with_url?(sources)
            feed_url = rss_entry_url(sources)
            tracker_id = extract_rss_tracker_identifier(sources)
            rss_tracker_lookup[feed_url] = tracker_id if tracker_id
            [feed_url]
          else
            sources.map do |tracker, nested|
              if tracker == 'rss'
                parse_tracker_sources(nested, rss_tracker_lookup, rss_context: true)
              elsif rss_context
                feed_url = rss_entry_url({ tracker => nested })
                tracker_id = extract_rss_tracker_identifier(nested)
                rss_tracker_lookup[feed_url] = tracker_id if tracker_id
                feed_url
              else
                tracker
              end
            end
          end
        when Array
          sources.map do |source|
            parse_tracker_sources(source, rss_tracker_lookup, rss_context: rss_context)
          end
        else
          []
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
        download_criteria[:whitelisted_extensions] = Array(download_criteria[:whitelisted_extensions]).flatten.compact.map(&:to_s).uniq
        download_criteria.merge(post_actions)
      end

      def tracker_login_metadata(tracker)
        return if tracker.to_s.strip.empty?

        path = File.join(app.tracker_dir, "#{tracker}.login.yml")
        return unless File.exist?(path)

        YAML.safe_load(File.read(path), aliases: true) || {}
      end

      def tracker_login_service
        @tracker_login_service ||= TrackerLoginService.new(app: app, speaker: speaker)
      end

      def rss_tracker_identifier(feed_url)
        (@rss_tracker_lookup || {})[feed_url]
      end

      def rss_hash_with_url?(value)
        value.is_a?(Hash) && (value.key?('url') || value.key?(:url))
      end

      def rss_entry_url(entry)
        return entry['url'] if entry.is_a?(Hash) && entry['url']
        return entry[:url] if entry.is_a?(Hash) && entry[:url]

        if entry.is_a?(Hash)
          key, value = entry.first
          return rss_entry_url(value) if rss_hash_with_url?(value)

          key
        else
          entry
        end
      end

      def extract_rss_tracker_identifier(options)
        return unless options.is_a?(Hash)

        options['tracker'] || options[:tracker]
      end

      def login_redirect?(page, metadata)
        login_url = metadata['login_url'].to_s
        return false if login_url.empty?

        page_uri = page.respond_to?(:uri) ? page.uri : nil
        page_uri && page_uri.to_s.start_with?(login_url)
      end

      def login_retryable?(error)
        return true if error.is_a?(LoginRequiredError)
        return error.response_code.to_s == '401' if defined?(Mechanize::ResponseCodeError) && error.is_a?(Mechanize::ResponseCodeError)

        false
      end
    end
  end
end

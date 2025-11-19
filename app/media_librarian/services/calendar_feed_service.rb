# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'date'
require 'cgi'

module MediaLibrarian
  module Services
    class CalendarFeedService < BaseService
      DEFAULT_WINDOW_DAYS = 30
      SOURCES_SEPARATOR = /[\s,|]+/.freeze

      def initialize(app: self.class.app, speaker: nil, file_system: nil, db: nil, providers: nil)
        super(app: app, speaker: speaker, file_system: file_system)
        @db = db || app&.db
        @providers = providers || default_providers
      end

      def refresh(date_range: default_date_range, limit: 100, sources: nil)
        return [] unless calendar_table_available?

        range = date_range.is_a?(Range) ? date_range : default_date_range
        normalized = collect_entries(range, limit, normalize_sources(sources))
        persist_entries(normalized)
        prune_entries(range)
        normalized
      end

      private

      attr_reader :db, :providers

      IMDB_GLOBAL_FEEDS = [
        { url: 'https://www.imdb.com/calendar/?type=MOVIE&ref_=rlm', media_type: 'movie' },
        { url: 'https://www.imdb.com/calendar/?type=TV&ref_=rlm', media_type: 'show' }
      ].freeze

      def calendar_table_available?
        db && db.table_exists?(:calendar_entries)
      end

      def collect_entries(date_range, limit, sources)
        active_providers = select_providers(sources)
        return [] if active_providers.empty?

        collected = active_providers.flat_map do |provider|
          fetched = safe_fetch(provider, date_range, limit)
          if provider.source == 'imdb' && fetched.empty?
            fallback = fallback_provider('tmdb', active_providers)
            fetched = safe_fetch(fallback, date_range, limit) if fallback
          end
          fetched
        end

        normalized = collected.filter_map { |entry| normalize_entry(entry) }
                               .uniq { |entry| [entry[:source], entry[:external_id]] }
        in_range = filter_entries_by_range(normalized, date_range)
        return in_range.first(limit) if in_range.length >= limit

        (in_range + (normalized - in_range)).first(limit)
      end

      def default_date_range
        today = Date.today
        (today - DEFAULT_WINDOW_DAYS)..(today + DEFAULT_WINDOW_DAYS)
      end

      def normalize_entry(entry)
        return unless entry.is_a?(Hash)

        release_date = parse_date(entry[:release_date])
        return unless release_date

        source = entry[:source].to_s.strip.downcase
        external_id = entry[:external_id].to_s.strip
        title = entry[:title].to_s.strip
        media_type = entry[:media_type].to_s.strip
        return if source.empty? || external_id.empty? || title.empty? || media_type.empty?

        {
          source: source,
          external_id: external_id,
          title: title,
          media_type: media_type,
          genres: Array(entry[:genres]).compact.map(&:to_s),
          languages: Array(entry[:languages]).compact.map(&:to_s),
          countries: Array(entry[:countries]).compact.map(&:to_s),
          rating: entry[:rating] ? entry[:rating].to_f : nil,
          release_date: release_date
        }
      end

      def filter_entries_by_range(entries, date_range)
        start_date, end_date = date_range_bounds(date_range)
        return entries unless start_date || end_date

        entries.select do |entry|
          release_date = entry[:release_date]
          next false unless release_date

          (start_date.nil? || release_date >= start_date) &&
            (end_date.nil? || release_date <= end_date)
        end
      end

      def prune_entries(date_range)
        return unless db

        start_date, end_date = date_range_bounds(date_range)
        db.delete_rows(:calendar_entries, {}, 'release_date <' => start_date) if start_date
        db.delete_rows(:calendar_entries, {}, 'release_date >' => end_date) if end_date
      end

      def date_range_bounds(range)
        return [nil, nil] unless range.is_a?(Range)

        start_date = parse_date(range.begin)
        end_date = parse_date(range.end)
        end_date = end_date - 1 if range.exclude_end? && end_date
        [start_date, end_date]
      rescue StandardError
        [nil, nil]
      end

      def normalize_sources(value)
        return nil if value.nil?

        tokens = Array(value).flat_map { |src| src.to_s.split(SOURCES_SEPARATOR) }
                              .map { |src| src.strip.downcase }
                              .reject(&:empty?)
        tokens.empty? ? nil : tokens
      end

      def parse_date(value)
        case value
        when Date
          value
        when Time, DateTime
          value.to_date
        else
          parse_date_string(value.to_s)
        end
      rescue ArgumentError
        nil
      end

      def parse_date_string(raw)
        value = raw.to_s.strip
        return nil if value.empty?

        Date.parse(value)
      rescue ArgumentError
        parse_slash_date(value)
      end

      def parse_slash_date(value)
        return nil unless value.match?(%r{\A\d{1,2}/\d{1,2}/\d{4}\z})

        Date.strptime(value, '%m/%d/%Y')
      rescue ArgumentError
        nil
      end

      def persist_entries(entries)
        return [] if entries.empty?

        db.insert_rows(:calendar_entries, entries, true)
        entries
      end

      def safe_fetch(provider, date_range, limit)
        provider.upcoming(date_range: date_range, limit: limit)
      rescue StandardError => e
        speaker.tell_error(e, "Calendar provider failure: #{provider.class.name}") if speaker
        []
      end

      def select_providers(sources)
        return providers if sources.nil? || sources.empty?

        providers.select do |provider|
          sources.include?(provider.source)
        end
      end

      def fallback_provider(name, excluded)
        return nil unless name

        providers.find do |provider|
          provider.source == name && !excluded.include?(provider)
        end
      end

      def default_providers
        config = app&.config
        return [] unless config.respond_to?(:[])

        providers = []
        tmdb_config = config['tmdb']
        if tmdb_config.is_a?(Hash)
          providers << TmdbCalendarProvider.new(
            api_key: tmdb_config['api_key'],
            language: tmdb_config['language'] || tmdb_config['languages'],
            region: tmdb_config['region'],
            speaker: speaker
          )
        end
        imdb_config = config['imdb']
        if imdb_provider_enabled?(imdb_config)
          providers << ImdbCalendarProvider.new(
            speaker: speaker,
            fetcher: build_imdb_fetcher
          )
        end
        trakt_config = config['trakt']
        if trakt_config.is_a?(Hash)
          providers << TraktCalendarProvider.new(
            client_id: trakt_config['client_id'],
            client_secret: trakt_config['client_secret'],
            speaker: speaker,
            fetcher: build_trakt_fetcher(
              trakt_config['client_id'],
              trakt_config['client_secret'],
              trakt_config['access_token']
            )
          )
        end
        providers.compact.select(&:available?)
      end

      def build_imdb_fetcher
        lambda do |date_range:, limit:|
          fetch_imdb_global_feed.first(limit)
        end
      end

      def imdb_provider_enabled?(config)
        case config
        when nil
          true
        when Hash
          config.fetch('enabled', true)
        else
          !!config
        end
      end

      def fetch_imdb_global_feed
        IMDB_GLOBAL_FEEDS.flat_map do |feed|
          fetch_imdb_feed(feed[:url], feed[:media_type])
        end
      end

      def fetch_imdb_feed(url, media_type)
        uri = URI.parse(url)
        response = Net::HTTP.get_response(uri)
        return [] unless response.is_a?(Net::HTTPSuccess)

        parse_imdb_feed(response.body, media_type)
      rescue StandardError => e
        speaker&.tell_error(e, "Calendar IMDb fetch failed for #{uri}") if defined?(uri)
        []
      end

      def parse_imdb_feed(html, media_type)
        items = extract_imdb_items(html)
        items.filter_map { |item| build_imdb_entry(item, media_type) }
      end

      def extract_imdb_items(html)
        data = extract_imdb_json(html)
        return [] unless data.is_a?(Hash)

        possible_paths = [
          %w[props pageProps contentData items],
          %w[props pageProps contentData calendarData],
          %w[props pageProps pageData contentData items],
          %w[props pageProps pageData contentData listItems],
          %w[pageProps contentData items],
          %w[data items],
          %w[items]
        ]

        possible_paths.each do |path|
          result = dig_path(data, path)
          return Array(result) if result
        end

        []
      end

      def extract_imdb_json(html)
        return if html.to_s.empty?

        script = html.match(/<script[^>]*id="__NEXT_DATA__"[^>]*>(?<json>.*?)<\/script>/m)
        return JSON.parse(CGI.unescapeHTML(script[:json])) if script

        react = html.match(/IMDbReactInitialState.push\((?<json>\{.*\})\);/m)
        return JSON.parse(react[:json]) if react
      rescue JSON::ParserError
        nil
      end

      def dig_path(data, path)
        path.reduce(data) do |memo, key|
          break unless memo.is_a?(Hash)

          memo[key]
        end
      end

      def build_imdb_entry(item, fallback_media_type)
        release_date = parse_imdb_release_date(item['releaseDate'] || item['release'])
        return unless release_date

        external_id = imdb_external_id(item)
        title = imdb_title(item)
        return if external_id.to_s.strip.empty? || title.to_s.strip.empty?

        {
          external_id: external_id,
          title: title,
          media_type: imdb_media_type(imdb_media_type_value(item, fallback_media_type)),
          genres: imdb_text_list(item.dig('genres', 'genres')),
          languages: imdb_text_list(item['spokenLanguages']),
          countries: imdb_text_list(item['countriesOfOrigin']),
          rating: safe_float(item.dig('ratingsSummary', 'aggregateRating')),
          release_date: release_date
        }
      end

      def imdb_external_id(item)
        raw = item['id'] || item['const'] || item.dig('title', 'id')
        return raw unless raw.is_a?(String)

        match = raw.match(/(tt\d+)/)
        match ? match[1] : raw
      end

      def imdb_title(item)
        item.dig('titleText', 'text') ||
          item.dig('originalTitleText', 'text') ||
          item['title']
      end

      def imdb_media_type_value(item, fallback)
        item.dig('titleType', 'text') ||
          item.dig('titleType', 'id') ||
          fallback
      end

      def imdb_text_list(entries)
        Array(entries).filter_map do |entry|
          case entry
          when Hash
            entry['text'] || entry['value'] || entry['id'] || entry.dig('name', 'text')
          else
            entry
          end
        end.map { |value| value.to_s.strip }.reject(&:empty?)
      end

      def parse_imdb_release_date(value)
        case value
        when Hash
          year = value['year'] || value[:year]
          month = value['month'] || value[:month] || 1
          day = value['day'] || value[:day] || 1
          return nil unless year

          Date.new(year.to_i, month.to_i, day.to_i)
        else
          parse_date(value)
        end
      rescue StandardError
        nil
      end

      def imdb_media_type(value)
        case value.to_s.strip.downcase
        when 'tv series', 'tv mini-series', 'tv episode', 'tv', 'show', 'tv show', 'series'
          'show'
        else
          'movie'
        end
      end

      def safe_float(value)
        return nil if value.to_s.strip.empty?

        Float(value)
      rescue ArgumentError, TypeError
        nil
      end

      def build_trakt_fetcher(client_id, client_secret, token)
        return nil if client_id.to_s.empty? || client_secret.to_s.empty?

        lambda do |date_range:, limit:|
          fetch_trakt_entries(
            client_id: client_id,
            token: token,
            date_range: date_range,
            limit: limit
          )
        end
      end

      def fetch_trakt_entries(client_id:, token:, date_range:, limit:)
        start_date = (date_range.first || Date.today)
        end_date = (date_range.last || start_date)
        days = [(end_date - start_date).to_i + 1, 1].max

        movies = trakt_request("/calendars/all/movies/#{start_date}/#{days}", client_id: client_id, token: token)
        shows = trakt_request("/calendars/all/shows/#{start_date}/#{days}", client_id: client_id, token: token)

        (parse_trakt_movies(movies) + parse_trakt_shows(shows)).first(limit)
      end

      def trakt_request(path, client_id:, token:)
        uri = URI::HTTPS.build(host: 'api.trakt.tv', path: path)
        request = Net::HTTP::Get.new(uri)
        request['Content-Type'] = 'application/json'
        request['trakt-api-version'] = '2'
        request['trakt-api-key'] = client_id.to_s
        request['Authorization'] = "Bearer #{token}" unless token.to_s.strip.empty?

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
        return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

        []
      rescue StandardError => e
        speaker&.tell_error(e, "Calendar Trakt fetch failed for #{path}")
        []
      end

      def parse_trakt_movies(payload)
        Array(payload).filter_map do |item|
          movie = item['movie'] || {}
          release_date = parse_date(item['released'] || item['release_date'] || item['first_aired'])
          build_trakt_entry(movie, 'movie', release_date)
        end
      end

      def parse_trakt_shows(payload)
        Array(payload).filter_map do |item|
          show = item['show'] || {}
          release_date = parse_date(item['first_aired'] || item.dig('episode', 'first_aired'))
          build_trakt_entry(show, 'show', release_date)
        end
      end

      def build_trakt_entry(record, media_type, release_date)
        return unless release_date

        external_id = trakt_external_id(record)
        title = record['title'].to_s
        return if external_id.to_s.empty? || title.empty?

        {
          external_id: external_id,
          title: title,
          media_type: media_type,
          genres: Array(record['genres']).compact.map(&:to_s),
          languages: wrap_string(record['language']),
          countries: wrap_string(record['country']),
          rating: safe_float(record['rating']),
          release_date: release_date
        }
      end

      def trakt_external_id(record)
        ids = record['ids'] || {}
        ids['imdb'] || ids['slug'] || ids['tmdb']&.to_s || ids['tvdb']&.to_s || ids['trakt']&.to_s
      end

      def wrap_string(value)
        return [] if value.to_s.strip.empty?

        [value.to_s]
      end

      class TmdbCalendarProvider
        API_HOST = 'api.themoviedb.org'

        attr_reader :source

        def initialize(api_key:, language: 'en', region: 'US', speaker: nil)
          @api_key = api_key.to_s
          @language = language.to_s.empty? ? 'en' : language.to_s
          @region = region.to_s.empty? ? 'US' : region.to_s
          @speaker = speaker
          @source = 'tmdb'
        end

        def available?
          !@api_key.empty? && @api_key != 'api_key'
        end

        def upcoming(date_range:, limit: 100)
          return [] unless available?

          movies = fetch_collection('/3/movie/upcoming', date_range, limit, :movie)
          shows = fetch_collection('/3/tv/on_the_air', date_range, limit, :tv)
          (movies + shows).first(limit)
        end

        private

        attr_reader :language, :region

        def fetch_collection(path, date_range, limit, kind)
          page = 1
          results = []
          loop do
            payload = get_json(path, page: page)
            break unless payload.is_a?(Hash) && payload['results'].is_a?(Array)

            payload['results'].each do |item|
              release_date = release_from(item, kind)
              next unless release_date && date_range.cover?(release_date)

              details = fetch_details(kind, item['id'])
              next unless details

              results << build_entry(details, kind, release_date)
              return results if results.length >= limit
            end

            page += 1
            break if page > payload.fetch('total_pages', 1).to_i
          end
          results
        end

        def release_from(item, kind)
          parse_date(kind == :movie ? item['release_date'] : item['first_air_date'])
        end

        def fetch_details(kind, id)
          path = kind == :movie ? "/3/movie/#{id}" : "/3/tv/#{id}"
          get_json(path)
        end

        def build_entry(details, kind, release_date)
          {
            source: source,
            external_id: "#{kind}-#{details['id']}",
            title: (kind == :movie ? details['title'] : details['name']) ||
                   details['original_title'] || details['original_name'] || '',
            media_type: kind == :movie ? 'movie' : 'show',
            genres: Array(details['genres']).filter_map { |genre| genre['name'] },
            languages: extract_languages(details),
            countries: extract_countries(details),
            rating: details['vote_average'],
            release_date: release_date
          }
        end

        def extract_languages(details)
          spoken = Array(details['spoken_languages']).filter_map { |lang| lang['english_name'] || lang['name'] }
          codes = Array(details['languages']).map(&:to_s)
          languages = spoken.empty? ? codes : spoken
          languages.empty? && details['original_language'] ? [details['original_language']] : languages
        end

        def extract_countries(details)
          prod = Array(details['production_countries']).filter_map { |country| country['name'] || country['iso_3166_1'] }
          origins = Array(details['origin_country']).map(&:to_s)
          prod.empty? ? origins : prod
        end

        def get_json(path, **query)
          uri = URI::HTTPS.build(host: API_HOST, path: path, query: build_query(query))
          response = Net::HTTP.get_response(uri)
          return unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)
        rescue StandardError => e
          @speaker&.tell_error(e, "Calendar TMDB fetch failed for #{uri}") if defined?(uri)
          nil
        end

        def build_query(query)
          params = { api_key: @api_key, language: language }
          params[:region] = region unless region.to_s.empty?
          params.merge!(query.compact)
          URI.encode_www_form(params)
        end

        def parse_date(value)
          return nil if value.to_s.strip.empty?

          Date.parse(value.to_s)
        rescue ArgumentError
          nil
        end
      end

      class ImdbCalendarProvider
        attr_reader :source

        def initialize(speaker: nil, fetcher: nil)
          @speaker = speaker
          @fetcher = fetcher
          @source = 'imdb'
        end

        def available?
          !@fetcher.nil?
        end

        def upcoming(date_range:, limit: 100)
          return [] unless available?

          fetch_entries(date_range, limit)
            .filter_map { |entry| normalize_entry(entry, date_range) }
            .first(limit)
        end

        private

        def fetch_entries(date_range, limit)
          return [] unless @fetcher

          @fetcher.call(date_range: date_range, limit: limit)
        rescue StandardError => e
          @speaker&.tell_error(e, 'Calendar IMDb fetch failed')
          []
        end

        def normalize_entry(entry, date_range)
          release_date = parse_date(entry[:release_date])
          return unless release_date && date_range.cover?(release_date)

          external_id = entry[:external_id].to_s.strip
          title = entry[:title].to_s.strip
          media_type = entry[:media_type].to_s.strip
          return if external_id.empty? || title.empty? || media_type.empty?

          {
            source: source,
            external_id: external_id,
            title: title,
            media_type: media_type,
            genres: Array(entry[:genres]).compact.map(&:to_s),
            languages: Array(entry[:languages]).compact.map(&:to_s),
            countries: Array(entry[:countries]).compact.map(&:to_s),
            rating: entry[:rating] ? entry[:rating].to_f : nil,
            release_date: release_date
          }
        end

        def parse_date(value)
          return value if value.is_a?(Date)

          Date.parse(value.to_s)
        rescue StandardError
          nil
        end
      end

      class TraktCalendarProvider
        attr_reader :source

        def initialize(client_id:, client_secret:, speaker: nil, fetcher: nil)
          @client_id = client_id.to_s
          @client_secret = client_secret.to_s
          @speaker = speaker
          @fetcher = fetcher
          @source = 'trakt'
        end

        def available?
          !@client_id.empty? && !@client_secret.empty?
        end

        def upcoming(date_range:, limit: 100)
          return [] unless available?

          fetch_entries(date_range, limit)
            .filter_map { |entry| normalize_entry(entry, date_range) }
            .first(limit)
        end

        private

        def fetch_entries(date_range, limit)
          return [] unless @fetcher

          @fetcher.call(date_range: date_range, limit: limit)
        rescue StandardError => e
          @speaker&.tell_error(e, 'Calendar Trakt fetch failed')
          []
        end

        def normalize_entry(entry, date_range)
          release_date = parse_date(entry[:release_date])
          return unless release_date && date_range.cover?(release_date)

          external_id = entry[:external_id].to_s.strip
          title = entry[:title].to_s.strip
          media_type = entry[:media_type].to_s.strip
          return if external_id.empty? || title.empty? || media_type.empty?

          {
            source: source,
            external_id: external_id,
            title: title,
            media_type: media_type,
            genres: Array(entry[:genres]).compact.map(&:to_s),
            languages: Array(entry[:languages]).compact.map(&:to_s),
            countries: Array(entry[:countries]).compact.map(&:to_s),
            rating: entry[:rating] ? entry[:rating].to_f : nil,
            release_date: release_date
          }
        end

        def parse_date(value)
          return value if value.is_a?(Date)

          Date.parse(value.to_s)
        rescue StandardError
          nil
        end
      end
    end
  end
end

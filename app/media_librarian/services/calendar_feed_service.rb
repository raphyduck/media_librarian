# frozen_string_literal: true

require 'date'
require 'themoviedb'
require 'json'
require 'httparty'
require_relative '../../../lib/imdb_api'
require 'trakt'

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

        normalized, stats = collect_entries(date_range, limit, normalize_sources(sources))
        speaker.speak_up("Calendar feed collected #{normalized.length} items")
        persist_entries(normalized)
        speaker.speak_up("Calendar feed persisted #{normalized.length} items#{summary_suffix(stats)}")
        normalized
      end

      private

      attr_reader :db, :providers

      def calendar_table_available?
        db && db.table_exists?(:calendar_entries)
      end

      def collect_entries(date_range, limit, sources)
        active_providers = select_providers(sources)
        return [[], {}] if active_providers.empty?

        stats = Hash.new { |h, k| h[k] = { fetched: 0, retained: 0, location: nil } }

        collected = active_providers.flat_map do |provider|
          fetched = fetch_from_provider(provider, date_range, limit, stats)
          if provider.source == 'imdb' && fetched.empty?
            fallback = fallback_provider('tmdb', active_providers)
            fetched = fetch_from_provider(fallback, date_range, limit, stats) if fallback
          end
          fetched
        end

        normalized = collected.map { |entry| normalize_entry(entry, date_range) }
                               .compact
                               .uniq { |entry| [entry[:source], entry[:external_id]] }
                               .first(limit)

        normalized.each { |entry| stats[entry[:source]][:retained] += 1 }
        log_provider_results(stats)
        log_entries(normalized)
        [normalized, stats]
      end

      def default_date_range
        today = Date.today
        today..(today + DEFAULT_WINDOW_DAYS)
      end

      def normalize_entry(entry, date_range)
        return unless entry.is_a?(Hash)

        release_date = parse_date(entry[:release_date])
        return unless release_date && date_range.cover?(release_date)

        source = entry[:source].to_s.strip.downcase
        external_id = entry[:external_id].to_s.strip
        title = entry[:title].to_s.strip
        media_type = entry[:media_type].to_s.strip
        return if source.empty? || external_id.empty? || title.empty? || media_type.empty?

        ids = default_ids(normalize_ids(entry[:ids] || entry['ids']), source, external_id)

        {
          source: source,
          external_id: external_id,
          title: title,
          media_type: media_type,
          genres: Array(entry[:genres]).compact.map(&:to_s),
          languages: Array(entry[:languages]).compact.map(&:to_s),
          countries: Array(entry[:countries]).compact.map(&:to_s),
          rating: entry[:rating] ? entry[:rating].to_f : nil,
          imdb_votes: entry[:imdb_votes].nil? ? nil : entry[:imdb_votes].to_i,
          poster_url: normalize_url(entry[:poster_url] || entry[:poster]),
          backdrop_url: normalize_url(entry[:backdrop_url] || entry[:backdrop]),
          release_date: release_date,
          ids: ids
        }
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

      def normalize_url(value)
        url = value.to_s.strip
        url.empty? ? nil : url
      end

      def normalize_ids(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, val), memo|
          memo[key.to_s] = val unless key.to_s.empty? || val.nil?
        end
      end

      def default_ids(ids, source, external_id)
        return ids unless ids.empty?
        return ids if source.empty? || external_id.empty?

        ids.merge(source => external_id)
      end

      def persist_entries(entries)
        return [] if entries.empty?

        db.insert_rows(:calendar_entries, entries, true)
        entries
      end

      def log_entries(entries)
        return unless speaker && entries.any?

        entries.each do |entry|
          message = {
            source: entry[:source],
            external_id: entry[:external_id],
            ids: entry[:ids],
            title: entry[:title],
            imdb_rating: entry[:rating],
            imdb_votes: entry[:imdb_votes]
          }.to_json

          speaker.speak_up("Calendar entry #{message}")
        end
      rescue StandardError
        nil
      end

      def safe_fetch(provider, date_range, limit)
        provider&.upcoming(date_range: date_range, limit: limit)
      rescue StandardError => e
        speaker.tell_error(e, "Calendar provider failure: #{provider.class.name}") if speaker
        []
      end

      def fetch_from_provider(provider, date_range, limit, stats)
        return [] unless provider

        source = provider.source
        location = provider_location(provider)
        stats[source][:location] ||= location
        speaker&.speak_up(
          "Calendar provider #{source} fetching #{date_range.first}..#{date_range.last} " \
          "(limit: #{limit}#{location ? ", path: #{location}" : ''})"
        )

        fetched = safe_fetch(provider, date_range, limit)
        stats[source][:fetched] += fetched.length
        stats[source][:location] ||= provider_location(provider)
        fetched
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

      def log_provider_results(stats)
        return unless speaker

        stats.each do |source, data|
          location_suffix = data[:location] ? " (path: #{data[:location]})" : ''
          speaker.speak_up(
            "Calendar provider #{source} returned #{data[:fetched]} items and kept #{data[:retained]}#{location_suffix}"
          )
        end
      end

      def provider_location(provider)
        return unless provider

        %i[last_request_path endpoint url base_url].each do |method|
          return provider.public_send(method) if provider.respond_to?(method)
        end

        nil
      end

      def summary_suffix(stats)
        return '' if stats.nil? || stats.empty?

        summary = stats.map { |source, data| "#{source}: #{data[:retained]}" }.join(', ')
        summary.empty? ? '' : " (#{summary})"
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
        providers << imdb_provider(imdb_config) if imdb_provider_enabled?(imdb_config)
        trakt_config = config['trakt']
        if trakt_config.is_a?(Hash)
          account_id = trakt_config['account_id']
          client_id = trakt_config['client_id']
          client_secret = trakt_config['client_secret']
          trakt_token = trakt_config['access_token'] || (app.respond_to?(:trakt) ? app.trakt&.token : nil)
          fetcher = build_trakt_fetcher(
            client_id,
            client_secret,
            trakt_token,
            account_id
          )

          unless fetcher
            speaker&.speak_up('Skipping Trakt provider: missing account_id, client_id or client_secret')
          end

          providers << TraktCalendarProvider.new(
            account_id: account_id,
            client_id: client_id,
            client_secret: client_secret,
            speaker: speaker,
            fetcher: fetcher
          )
        end
        providers.compact.select(&:available?)
      end

      def imdb_provider(config)
        ImdbCalendarProvider.new(
          speaker: speaker,
          fetcher: build_imdb_fetcher(config)
        )
      end

      def build_imdb_fetcher(config)
        api = ImdbApi.new(
          base_url: config_value(config, 'base_url'),
          region: config_value(config, 'region'),
          api_key: config_value(config, 'api_key'),
          speaker: speaker
        )

        lambda do |date_range:, limit:|
          speaker&.speak_up("IMDb calendar fetch #{date_range.first}..#{date_range.last} (limit: #{limit})")
          api.calendar(date_range: date_range, limit: limit)
        rescue StandardError => e
          speaker&.tell_error(e, 'IMDB calendar fetch failed')
          []
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

      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config[key]
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

      def build_trakt_fetcher(client_id, client_secret, token, account_id)
        return nil if client_id.to_s.empty? || client_secret.to_s.empty? || account_id.to_s.empty?

        lambda do |date_range:, limit:|
          fetch_trakt_entries(
            date_range: date_range,
            limit: limit,
            client_id: client_id,
            client_secret: client_secret,
            account_id: account_id,
            token: token
          )
        end
      end

      def fetch_trakt_entries(date_range:, limit:, client_id:, client_secret:, account_id:, token: nil)
        start_date = (date_range.first || Date.today)
        end_date = (date_range.last || start_date)
        days = [(end_date - start_date).to_i + 1, 1].max

        fetcher = trakt_calendar_client(
          client_id: client_id,
          client_secret: client_secret,
          account_id: account_id,
          token: token
        )

        movies = TraktAgent.fetch_calendar_entries(:movies, start_date, days, fetcher: fetcher)
        shows = TraktAgent.fetch_calendar_entries(:shows, start_date, days, fetcher: fetcher)

        parsed_movies, movie_error = parse_trakt_movies(movies)
        parsed_shows, show_error = parse_trakt_shows(shows)

        {
          entries: (parsed_movies + parsed_shows).first(limit),
          errors: [movie_error, show_error].compact
        }
      rescue StandardError => e
        speaker&.tell_error(e, 'Calendar Trakt fetch failed')
        { entries: [], errors: [e.message] }
      end

      def trakt_calendar_client(client_id:, client_secret:, account_id:, token: nil)
        Trakt.new(
          client_id: client_id,
          client_secret: client_secret,
          account_id: account_id,
          token: normalize_trakt_token(token),
          speaker: speaker
        )
      end

      def normalize_trakt_token(token)
        return token if token.is_a?(Hash)

        token_value = token.to_s.strip
        token_value.empty? ? nil : { access_token: token_value }
      end

      def parse_trakt_movies(payload)
        items, error = validate_trakt_payload(payload, 'Calendar Trakt movies payload')
        return [[], error] if error

        [
          items.filter_map do |item|
            movie = item['movie']
            next unless movie.is_a?(Hash)

            release_date = parse_date(item['released'] || item['release_date'] || item['first_aired'])
            build_trakt_entry(movie, 'movie', release_date)
          end,
          nil
        ]
      end

      def parse_trakt_shows(payload)
        items, error = validate_trakt_payload(payload, 'Calendar Trakt shows payload')
        return [[], error] if error

        [
          items.filter_map do |item|
            show = item['show']
            next unless show.is_a?(Hash)

            release_date = parse_date(item['first_aired'] || item.dig('episode', 'first_aired'))
            build_trakt_entry(show, 'show', release_date)
          end,
          nil
        ]
      end

      def validate_trakt_payload(payload, context)
        if payload.nil? || (payload.respond_to?(:empty?) && payload.empty?)
          return log_trakt_payload_error('Trakt payload missing or empty', context, payload)
        end

        items = Array(payload)
        return [items, nil] if items.all?(Hash)

        log_trakt_payload_error('Invalid Trakt payload format', context, items)
      end

      def log_trakt_payload_error(message, context, payload)
        summary = payload_summary(payload)
        speaker&.tell_error(StandardError.new(message), summary ? "#{context} (#{summary})" : context)
        [[], message]
      end

      def payload_summary(payload)
        return nil if payload.nil?

        size = payload.respond_to?(:size) ? payload.size : nil
        summary_parts = [payload.class.name, ("size=#{size}" if size)]
        summary_parts.compact.join(' ')
      end

      def build_trakt_entry(record, media_type, release_date)
        return unless release_date

        ids = trakt_ids(record)
        external_id = trakt_external_id(ids)
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
          imdb_votes: nil,
          poster_url: trakt_image(record, %w[images poster full], %w[images poster medium], %w[poster]),
          backdrop_url: trakt_image(record, %w[images fanart full], %w[images backdrop full], %w[fanart], %w[backdrop]),
          release_date: release_date,
          ids: ids
        }
      end

      def trakt_external_id(ids)
        ids['imdb'] || ids['slug'] || ids['tmdb']&.to_s || ids['tvdb']&.to_s || ids['trakt']&.to_s
      end

      def trakt_ids(record)
        raw_ids = record['ids'] || {}
        raw_ids.each_with_object({}) do |(key, val), memo|
          memo[key.to_s] = val unless key.to_s.empty? || val.nil?
        end
      end

      def trakt_image(record, *paths)
        paths.filter_map do |path|
          value = path.reduce(record) { |memo, key| memo.respond_to?(:[]) ? memo[key] || memo[key&.to_sym] : nil }
          value = value[:full] || value['full'] if value.is_a?(Hash)
          value.to_s.strip unless value.to_s.strip.empty?
        end.first
      end

      def wrap_string(value)
        return [] if value.to_s.strip.empty?

        [value.to_s]
      end

      class TmdbCalendarProvider
        attr_reader :source, :last_request_path

        def initialize(api_key:, language: 'en', region: 'US', speaker: nil, client: Tmdb)
          @api_key = api_key.to_s
          @language = language.to_s.empty? ? 'en' : language.to_s
          @region = region.to_s.empty? ? 'US' : region.to_s
          @speaker = speaker
          @client = client
          @source = 'tmdb'
          configure_client
        end

        def available?
          !@api_key.empty? && @api_key != 'api_key'
        end

        def upcoming(date_range:, limit: 100)
          return [] unless available?

          movies = fetch_titles_for(:movie, date_range, limit)
          remaining = [limit - movies.length, 0].max
          shows = fetch_titles_for(:tv, date_range, remaining)
          (movies + shows).first(limit)
        end

        private

        attr_reader :language, :region, :client

        def configure_client
          return unless available?
          return unless client.const_defined?(:Api)

          client::Api.key(@api_key)
          client::Api.language(language)
          client::Api.config[:region] = region if region
        end

        def fetch_titles_for(kind, date_range, limit)
          fetch_paths(kind, date_range).each_with_object([]) do |path, results|
            break results if results.length >= limit

            needed = limit - results.length
            results.concat(fetch_titles(path, kind, date_range, needed, date_params(kind, date_range)))
          end
        end

        def fetch_titles(path, kind, date_range, limit, params = {})
          return [] if limit.to_i <= 0

          page = 1
          results = []
          loop do
            payload = fetch_page(path, kind, page, params)
            break unless payload

            items = payload.is_a?(Array) ? payload : Array(payload['results'])
            items.each do |item|
              release_date = release_from(item, kind)
              next unless release_date && date_range.cover?(release_date)

              details = fetch_details(kind, value_from(item, :id))
              next unless details

              results << build_entry(details, kind, release_date)
              return results if results.length >= limit
            end

            page += 1
            total_pages = payload.is_a?(Hash) ? payload.fetch('total_pages', 1).to_i : 1
            break if page > total_pages
          end
          results
        end

        def fetch_page(path, kind, page, params = {})
          @last_request_path = path
          params = { page: page }.merge(params || {}).compact

          if page.to_i == 1
            begin
              case kind
              when :movie
                return client::Movie.upcoming if path == '/movie/upcoming' && client.const_defined?(:Movie) &&
                                                 client::Movie.respond_to?(:upcoming)
                return client::Movie.now_playing if path == '/movie/now_playing' && client.const_defined?(:Movie) &&
                                                    client::Movie.respond_to?(:now_playing)
              when :tv
                return client::TV.on_the_air if path == '/tv/on_the_air' && client.const_defined?(:TV) &&
                                                 client::TV.respond_to?(:on_the_air)
                return client::TV.airing_today if path == '/tv/airing_today' && client.const_defined?(:TV) &&
                                                    client::TV.respond_to?(:airing_today)
              end
            rescue ArgumentError
              nil
            end
          end

          return client::Api.request(path, params) if client.const_defined?(:Api) && client::Api.respond_to?(:request)

          http_request(path, params)
        rescue StandardError => e
          report_error(e, "Calendar TMDB fetch failed for #{path}")
          nil
        end

        def http_request(path, params)
          query = params.merge(api_key: @api_key, language: language, region: region).compact
          response = HTTParty.get("https://api.themoviedb.org/3#{path}", query: query)
          return JSON.parse(response.body) if response.success?

          report_error(StandardError.new("TMDB #{response.code}"), "Calendar TMDB fetch failed for #{path}")
          nil
        rescue StandardError => e
          report_error(e, "Calendar TMDB fetch failed for #{path}")
          nil
        end

        def release_from(item, kind)
          parse_date(value_from(item, kind == :movie ? :release_date : :first_air_date))
        end

        def fetch_paths(kind, date_range)
          today = Date.today
          range_start = date_range.first || today
          range_end = date_range.last || today
          paths = []

          if range_start < today
            paths << (kind == :movie ? '/movie/now_playing' : '/tv/airing_today')
            paths << (kind == :movie ? '/discover/movie' : '/discover/tv')
          end

          paths << (kind == :movie ? '/movie/upcoming' : '/tv/on_the_air') if range_end >= today
          paths.uniq
        end

        def date_params(kind, date_range)
          start_date = date_range.first
          end_date = date_range.last
          return {} unless start_date && end_date

          if kind == :movie
            {
              'primary_release_date.gte': start_date.to_s,
              'primary_release_date.lte': end_date.to_s,
              'release_date.gte': start_date.to_s,
              'release_date.lte': end_date.to_s
            }
          else
            {
              'first_air_date.gte': start_date.to_s,
              'first_air_date.lte': end_date.to_s
            }
          end
        end

        def value_from(item, *keys)
          keys.each do |key|
            return item.public_send(key) if item.respond_to?(key)
            return item.public_send(key.to_s) if item.respond_to?(key.to_s)
            return item[key] if item.respond_to?(:[]) && item[key]
            return item[key.to_s] if item.respond_to?(:[]) && item[key.to_s]
          end
          nil
        end

        def fetch_details(kind, id)
          (kind == :movie ? client::Movie : client::TV).detail(id)
        rescue StandardError => e
          report_error(e, "Calendar TMDB detail fetch failed for #{kind} #{id}")
          nil
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
            imdb_votes: details['vote_count'],
            poster_url: image_url(details['poster_path'], 'w342'),
            backdrop_url: image_url(details['backdrop_path'], 'w780'),
            release_date: release_date,
            ids: tmdb_ids(details)
          }
        end

        def tmdb_ids(details)
          ids = { 'tmdb' => details['id'] }
          imdb_id = details['imdb_id'].to_s
          ids['imdb'] = imdb_id unless imdb_id.empty?
          ids
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

        def parse_date(value)
          return nil if value.to_s.strip.empty?

          Date.parse(value.to_s)
        rescue ArgumentError
          nil
        end

        def image_url(path, size)
          return nil if path.to_s.strip.empty?

          "https://image.tmdb.org/t/p/#{size}#{path}"
        end

        def report_error(error, message)
          @speaker&.tell_error(error, message)
        end
      end

      class ImdbCalendarProvider
        attr_reader :source, :last_request_path

        def initialize(speaker: nil, fetcher: nil)
          @speaker = speaker
          @fetcher = fetcher
          @source = 'imdb'
          @last_request_path = nil
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

          entries =
            Array(@fetcher.call(date_range: date_range, limit: limit))
              .filter_map { |record| build_entry(record) }

          if entries.empty?
            @speaker&.speak_up("Calendar provider #{source} returned no entries for #{date_range.first}..#{date_range.last}")
          end

          entries
        rescue StandardError => e
          @speaker&.tell_error(e, 'Calendar IMDb fetch failed')
          []
        end

        def build_entry(record)
          imdb_id = imdb_external_id(record)

          {
            external_id: imdb_id,
            title: imdb_title(record),
            media_type: imdb_media_type(record),
            genres: imdb_list(record, :genres, :genre, %i[genres genres]),
            languages: imdb_list(record, :languages, :spoken_languages, :spokenLanguages),
          countries: imdb_list(record, :countries, :countries_of_origin, :countriesOfOrigin),
          rating: imdb_rating(record),
          imdb_votes: imdb_votes(record),
          poster_url: imdb_image(record),
          backdrop_url: imdb_image(record, :backdrop),
          release_date: imdb_release_date(record),
          ids: imdb_ids(imdb_id)
        }
        end

        def imdb_release_date(record)
          value = record_value(record, :release_date, :releaseDate, %i[release date])
          parse_date(value)
        rescue StandardError
          nil
        end

        def imdb_external_id(record)
          raw = record_value(record, :external_id, :imdb_id, :id, %i[title id])
          return raw unless raw.is_a?(String)

          raw[%r{tt\d+}] || raw
        end

        def imdb_ids(imdb_id)
          imdb_id.to_s.empty? ? {} : { 'imdb' => imdb_id }
        end

        def imdb_title(record)
          value = record_value(
            record,
            :title,
            :titleText,
            %i[titleText text],
            %i[title_text text],
            :originalTitleText,
            %i[originalTitleText text],
            %i[original_title_text text]
          )

          return value[:text] || value['text'] if value.is_a?(Hash)

          value
        end

        def imdb_media_type(record)
          type = record_value(record, :media_type, :type, :title_type, %i[titleType id], %i[titleType text])
          normalized = type.to_s.downcase
          return 'movie' if normalized.include?('movie') || normalized.include?('film')
          return 'show' if normalized.include?('tv') || normalized.include?('series') || normalized.include?('show')

          normalized.empty? ? 'movie' : normalized
        end

        def imdb_list(record, *keys)
          value = record_value(record, *keys)
          value = value['genres'] || value[:genres] if value.is_a?(Hash) && (value.key?('genres') || value.key?(:genres))
          Array(value).filter_map do |entry|
            case entry
            when Hash
              entry[:text] || entry['text'] || entry[:value] || entry['value'] || entry[:id] || entry['id'] || entry.dig(:name, :text) || entry.dig('name', 'text')
            else
              entry
            end
          end.map { |item| item.to_s.strip }.reject(&:empty?)
        end

        def imdb_rating(record)
          rating = record_value(record, :rating, %i[ratings_summary aggregate_rating], %i[ratingsSummary aggregateRating])
          return rating.to_f if rating

          nil
        end

        def imdb_votes(record)
          votes = record_value(record, :votes, %i[ratings_summary vote_count], %i[ratingsSummary voteCount])
          return if votes.nil?

          votes.to_i
        end

        def record_value(record, *keys)
          keys.compact.each do |key|
            value =
              if key.is_a?(Array)
                key.reduce(record) { |memo, part| memo_value(memo, part) }
              else
                memo_value(record, key)
              end

            return value unless value.nil?
          end

          nil
        end

        def memo_value(record, key)
          return unless record

          if record.is_a?(Hash)
            record[key] || record[key.to_s] || record[key.to_sym]
          elsif record.respond_to?(key)
            record.public_send(key)
          end
        end

        def imdb_image(record, key = nil)
          value = record_value(record, key || :primaryImage, :primary_image, %i[primaryImage url], %i[primary_image url],
                                %i[image url], :image)
          url = value.is_a?(Hash) ? value[:url] || value['url'] : value
          url = url[:url] || url['url'] if url.is_a?(Hash)
          url = url.to_s.strip
          url.empty? ? nil : url
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
            imdb_votes: entry[:imdb_votes].nil? ? nil : entry[:imdb_votes].to_i,
            poster_url: imdb_image(entry, :poster_url),
            backdrop_url: imdb_image(entry, :backdrop_url),
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
        attr_reader :source, :last_request_path

        def initialize(account_id:, client_id:, client_secret:, speaker: nil, fetcher: nil)
          @account_id = account_id.to_s
          @client_id = client_id.to_s
          @client_secret = client_secret.to_s
          @speaker = speaker
          @fetcher = fetcher
          @source = 'trakt'
          @last_request_path = nil
        end

        def available?
          !@account_id.empty? && !@client_id.empty? && !@client_secret.empty?
        end

        def upcoming(date_range:, limit: 100)
          return [] unless available?

          fetch_entries(date_range, limit)
            .filter_map { |entry| normalize_entry(entry, date_range) }
            .first(limit)
        end

        private

        def fetch_entries(date_range, limit)
          unless available?
            message = 'Trakt account_id is required'
            @speaker&.tell_error(StandardError.new(message), message)
            return []
          end

          unless @fetcher
            @speaker&.speak_up('Trakt fetch skipped: no fetcher')
            return []
          end

          result = @fetcher.call(date_range: date_range, limit: limit)
          entries, errors = normalize_fetch_result(result)
          if errors.any?
            @speaker&.tell_error(StandardError.new(errors.join('; ')), 'Calendar Trakt fetch failed')
          end
          entries
        rescue StandardError => e
          @speaker&.tell_error(e, 'Calendar Trakt fetch failed')
          []
        end

        def normalize_fetch_result(result)
          if result.is_a?(Hash)
            return [Array(result[:entries]), Array(result[:errors]).compact]
          end

          [Array(result), []]
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
          imdb_votes: entry[:imdb_votes].nil? ? nil : entry[:imdb_votes].to_i,
          poster_url: entry[:poster_url],
          backdrop_url: entry[:backdrop_url],
          release_date: release_date,
          ids: normalize_ids(entry[:ids] || entry['ids'])
        }
        end

        def parse_date(value)
          return value if value.is_a?(Date)

          Date.parse(value.to_s)
        rescue StandardError
          nil
        end

        def normalize_ids(value)
          return {} unless value.is_a?(Hash)

          value.each_with_object({}) do |(key, val), memo|
            memo[key.to_s] = val unless key.to_s.empty? || val.nil?
          end
        end
      end
    end
  end
end

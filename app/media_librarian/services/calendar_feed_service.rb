# frozen_string_literal: true

require 'date'
require 'time'
require 'themoviedb'
require 'json'
require 'httparty'
require_relative '../../../lib/omdb_api'
require_relative '../../../lib/simple_speaker'
require 'trakt'

module MediaLibrarian
  module Services
    class CalendarFeedService < BaseService
      AuthenticationError = Class.new(StandardError)
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
        normalized = enrich_with_omdb(normalized)
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

      def omdb_provider(config)
        api_key = config_value(config, 'api_key').to_s
        return if api_key.empty?

        OmdbCalendarProvider.new(
          speaker: speaker,
          api_key: api_key,
          base_url: config_value(config, 'base_url')
        )
      end

      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config[key]
      end

      def omdb_detail_api
        return @omdb_detail_api if defined?(@omdb_detail_api)

        config = app&.config
        omdb_config = config.is_a?(Hash) ? config['omdb'] : nil
        api_key = config_value(omdb_config, 'api_key').to_s
        @omdb_detail_api = api_key.empty? ? nil : OmdbApi.new(api_key: api_key, base_url: config_value(omdb_config, 'base_url'), speaker: speaker)
      end

      def enrich_with_omdb(entries)
        api = omdb_detail_api
        return entries unless api

        entries.each do |entry|
          imdb_id = imdb_id_for(entry)
          next unless imdb_id
          next unless entry[:media_type] == 'movie'

          details = omdb_details(api, imdb_id)
          next unless details

          entry[:rating] = details[:rating] unless details[:rating].nil?
          entry[:imdb_votes] = details[:imdb_votes] unless details[:imdb_votes].nil?
          entry[:poster_url] ||= details[:poster_url]
          entry[:backdrop_url] ||= details[:backdrop_url]
        end

        entries
      end

      def omdb_details(api, imdb_id)
        return nil if @omdb_enrichment_failed

        @omdb_detail_cache ||= {}
        return @omdb_detail_cache[imdb_id] if @omdb_detail_cache.key?(imdb_id)

        @omdb_detail_cache[imdb_id] = api.title(imdb_id)
      rescue StandardError => e
        speaker&.tell_error(e, 'Calendar OMDb enrichment failed')
        @omdb_enrichment_failed = true
        nil
      end

      def imdb_id_for(entry)
        ids = entry[:ids]
        return unless ids.is_a?(Hash)

        ids['imdb'] || ids[:imdb]
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
          with_trakt_output_capture do
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
      end

      def fetch_trakt_entries(date_range:, limit:, client_id:, client_secret:, account_id:, token: nil)
        start_date = (date_range.first || Date.today)
        end_date = (date_range.last || start_date)
        days = [(end_date - start_date).to_i + 1, 1].max

        validated_token = ensure_trakt_token!(token)

        fetcher = trakt_calendar_client(
          client_id: client_id,
          client_secret: client_secret,
          account_id: account_id,
          token: validated_token
        )

        movies = trakt_calendar_payload(:movies, fetcher, start_date, days)
        shows = trakt_calendar_payload(:shows, fetcher, start_date, days)

        parsed_movies, movie_error = parse_trakt_movies(movies)
        parsed_shows, show_error = parse_trakt_shows(shows)

        {
          entries: (parsed_movies + parsed_shows).first(limit),
          errors: [movie_error, show_error].compact
        }
      rescue AuthenticationError => e
        speaker&.tell_error(e, 'Calendar Trakt authentication failed')
        _, movie_error = validate_trakt_payload(nil, 'Calendar Trakt movies payload', e.message)
        _, show_error = validate_trakt_payload(nil, 'Calendar Trakt shows payload', e.message)
        { entries: [], errors: [movie_error, show_error].compact }
      rescue StandardError => e
        speaker&.tell_error(e, 'Calendar Trakt fetch failed')
        { entries: [], errors: [e.message] }
      end

      def trakt_calendar_payload(type, fetcher, start_date, days)
        payload = with_trakt_output_capture do
          TraktAgent.fetch_calendar_entries(type, start_date, days, fetcher: fetcher)
        end
        return payload if payload
        return [] if trakt_no_content?(fetcher)

        fallback = trakt_fallback_calendar(fetcher)
        payload = with_trakt_output_capture do
          TraktAgent.fetch_calendar_entries(type, start_date, days, fetcher: fallback)
        end if fallback
        return payload if payload
        return [] if trakt_no_content?(fallback)

        raise StandardError, trakt_payload_error(type, fetcher, start_date, days)
      end

      def trakt_fallback_calendar(fetcher)
        return unless fetcher&.respond_to?(:calendar)

        fallback = fetcher.calendar
        fallback if fallback != fetcher
      end

      def trakt_no_content?(fetcher)
        return false unless fetcher&.respond_to?(:last_response)

        response = fetcher.last_response
        response.respond_to?(:code) && response.code.to_i == 204
      end

      def trakt_payload_error(type, fetcher, start_date, days)
        parts = ["Trakt #{type} calendar returned no data for #{start_date}..#{start_date + days - 1}"]
        if (location = provider_location(fetcher))
          parts << "path: #{location}"
        end
        if fetcher.respond_to?(:last_response) && (response = fetcher.last_response)
          status = response.respond_to?(:code) ? response.code : nil
          body = response.respond_to?(:body) ? response.body : nil
          details = [status && "status #{status}", body && "body #{body}"].compact.join(', ')
          parts << details unless details.empty?
        end
        parts.join(' | ')
      end

      def trakt_calendar_client(client_id:, client_secret:, account_id:, token: nil)
        with_trakt_output_capture do
          Trakt.new(
            client_id: client_id,
            client_secret: client_secret,
            account_id: account_id,
            token: ensure_trakt_token!(token),
            speaker: speaker
          )
        end
      end

      def with_trakt_output_capture
        original_stdout, original_stderr = $stdout, $stderr
        proxy = trakt_output_proxy(original_stdout, original_stderr)
        $stdout = proxy
        $stderr = proxy
        yield
      ensure
        $stdout = original_stdout
        $stderr = original_stderr
      end

      def trakt_output_proxy(original_stdout = $stdout, original_stderr = $stderr)
        return $stdout unless speaker

        proxy = Object.new
        output = ->(arg) { speaker.daemon_send(arg.to_s, stdout: original_stdout, stderr: original_stderr) }
        %i[write puts print].each do |method|
          proxy.define_singleton_method(method) do |*args|
            args = ["\n"] if args.empty? && method == :puts
            args.each { |arg| output.call(arg) }
          end
        end
        proxy
      end

      def normalize_trakt_token(token)
        return token if token.is_a?(Hash)

        token_value = token.to_s.strip
        token_value.empty? ? nil : { access_token: token_value }
      end

      def ensure_trakt_token!(token)
        normalized = normalize_trakt_token(token)
        token_value = trakt_access_token(normalized)
        raise AuthenticationError, 'Trakt access token is missing or invalid' if token_value.empty?

        expires_at = trakt_token_expiry(normalized)
        raise AuthenticationError, 'Trakt access token has expired' if expires_at && expires_at <= Time.now

        return normalized unless normalized.is_a?(Hash)

        normalized.merge(access_token: token_value)
      end

      def trakt_access_token(token)
        return '' unless token.is_a?(Hash)

        (token[:access_token] || token['access_token']).to_s.strip
      end

      def trakt_token_expiry(token)
        raw = token.is_a?(Hash) ? token[:expires_at] || token['expires_at'] : nil
        case raw
        when Time
          raw
        when DateTime
          raw.to_time
        else
          Time.parse(raw.to_s)
        end
      rescue ArgumentError, TypeError
        nil
      end

      def parse_trakt_movies(payload, error_message: nil)
        items, error = validate_trakt_payload(payload, 'Calendar Trakt movies payload', error_message)
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

      def parse_trakt_shows(payload, error_message: nil)
        items, error = validate_trakt_payload(payload, 'Calendar Trakt shows payload', error_message)
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

      def validate_trakt_payload(payload, context, fallback_error = nil)
        if payload.nil? || (payload.respond_to?(:empty?) && payload.empty?)
          return log_trakt_payload_error(fallback_error || 'Trakt payload missing or empty', context, payload)
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
      class OmdbCalendarProvider
        attr_reader :source, :last_request_path

        def initialize(api_key:, base_url: nil, speaker: nil, fetcher: nil)
          @api_key = api_key.to_s
          @base_url = base_url
          @speaker = speaker
          @fetcher = fetcher
          @source = 'omdb'
          @last_request_path = nil
        end

        def available?
          !@api_key.empty? || !@fetcher.nil?
        end

        def upcoming(date_range:, limit: 100)
          return [] unless available?

          fetch_entries(date_range, limit).first(limit)
        end

        private

        def fetch_entries(date_range, limit)
          fetcher = ensure_fetcher
          entries = Array(fetcher.call(date_range: date_range, limit: limit))
          @last_request_path = fetcher.respond_to?(:last_request_path) ? fetcher.last_request_path : api_last_request_path(fetcher)

          normalized = entries.filter_map { |entry| normalize_entry(entry, date_range) }
          if normalized.empty?
            @speaker&.speak_up("Calendar provider #{source} returned no entries for #{date_range.first}..#{date_range.last}")
          end

          normalized
        rescue StandardError => e
          @speaker&.tell_error(e, 'Calendar OMDb fetch failed')
          []
        end

        def ensure_fetcher
          return @fetcher if @fetcher

          api = OmdbApi.new(api_key: @api_key, base_url: @base_url, speaker: @speaker)
          @api_client = api
          @fetcher = lambda do |date_range:, limit:|
            api.calendar(date_range: date_range, limit: limit)
          end
        end

        def api_last_request_path(fetcher)
          return unless defined?(@api_client)

          @api_client.last_request_path if fetcher && @api_client.respond_to?(:last_request_path)
        end

        def normalize_entry(entry, date_range)
          release_date = parse_date(entry[:release_date] || entry['release_date'] || entry['Released'] || entry['DVD'])
          return unless release_date && date_range.cover?(release_date)

          external_id = fetch_value(entry, :external_id, :imdbID, :imdb_id)
          title = fetch_value(entry, :title, :Title)
          media_type = normalize_type(fetch_value(entry, :media_type, :Type))
          return if external_id.to_s.strip.empty? || title.to_s.strip.empty? || media_type.empty?

          {
            source: source,
            external_id: external_id.to_s,
            title: title.to_s,
            media_type: media_type,
            genres: list_from(entry, :genres, :Genre),
            languages: list_from(entry, :languages, :Language),
            countries: list_from(entry, :countries, :Country),
            rating: float_value(fetch_value(entry, :rating, :imdbRating)),
            imdb_votes: votes(fetch_value(entry, :imdb_votes, :imdbVotes)),
            poster_url: url_value(fetch_value(entry, :poster_url, :Poster)),
            backdrop_url: url_value(fetch_value(entry, :backdrop_url, :Backdrop)),
            release_date: release_date,
            ids: ids_for(external_id)
          }
        end

        def normalize_type(value)
          type = value.to_s.downcase
          return 'movie' if type == 'movie'
          return 'show' if type == 'series' || type.include?('series')

          type.empty? ? 'movie' : type
        end

        def list_from(record, *keys)
          value = fetch_value(record, *keys)
          return [] if value.nil?

          Array(value.is_a?(String) ? value.split(',') : value).map { |item| item.to_s.strip }.reject(&:empty?)
        end

        def fetch_value(record, *keys)
          keys.each do |key|
            next unless key
            value = record[key] || record[key.to_s] || record[key.to_sym]
            return value unless value.nil?
          end
          nil
        end

        def parse_date(value)
          return value if value.is_a?(Date)

          Date.parse(value.to_s)
        rescue StandardError
          nil
        end

        def votes(value)
          return nil if value.nil?

          value.to_s.delete(',').to_i
        rescue StandardError
          nil
        end

        def float_value(value)
          return nil if value.nil? || value.to_s.strip.empty?

          value.to_f
        rescue StandardError
          nil
        end

        def url_value(value)
          url = value.to_s.strip
          url.empty? ? nil : url
        end

        def ids_for(imdb_id)
          imdb_id.to_s.empty? ? {} : { 'imdb' => imdb_id }
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

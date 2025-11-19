# frozen_string_literal: true

require 'date'
require 'themoviedb'
require 'imdb_party'

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

        normalized = collect_entries(date_range, limit, normalize_sources(sources))
        persist_entries(normalized)
        normalized
      end

      private

      attr_reader :db, :providers

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

        collected.map { |entry| normalize_entry(entry, date_range) }
                 .compact
                 .uniq { |entry| [entry[:source], entry[:external_id]] }
                 .first(limit)
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
        client = ImdbParty::Imdb.new

        lambda do |date_range:, limit:|
          return [] unless client.respond_to?(:calendar)

          Array(client.calendar(date_range: date_range, limit: limit)).first(limit)
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

      def build_trakt_fetcher(client_id, client_secret, _token)
        return nil if client_id.to_s.empty? || client_secret.to_s.empty?

        lambda do |date_range:, limit:|
          fetch_trakt_entries(date_range: date_range, limit: limit)
        end
      end

      def fetch_trakt_entries(date_range:, limit:)
        start_date = (date_range.first || Date.today)
        end_date = (date_range.last || start_date)
        days = [(end_date - start_date).to_i + 1, 1].max

        movies = TraktAgent.calendars__all_movies(start_date, days) || []
        shows = TraktAgent.calendars__all_shows(start_date, days) || []

        (parse_trakt_movies(movies) + parse_trakt_shows(shows)).first(limit)
      rescue StandardError => e
        speaker&.tell_error(e, 'Calendar Trakt fetch failed')
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
        attr_reader :source

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

          movies = fetch_titles('/movie/upcoming', :movie, date_range, limit)
          remaining = [limit - movies.length, 0].max
          shows = fetch_titles('/tv/on_the_air', :tv, date_range, remaining)
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

        def fetch_titles(path, kind, date_range, limit)
          return [] if limit.to_i <= 0

          page = 1
          results = []
          loop do
            payload = fetch_page(path, kind, page)
            break unless payload

            Array(payload['results']).each do |item|
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

        def fetch_page(path, kind, page)
          payload =
            case kind
            when :movie
              client::Movie.upcoming(page)
            when :tv
              client::TV.on_the_air(page)
            else
              raise ArgumentError, "Unsupported kind: #{kind}"
            end

          payload
        rescue StandardError => e
          report_error(e, "Calendar TMDB fetch failed for #{path}")
          nil
        end

        def release_from(item, kind)
          parse_date(kind == :movie ? item['release_date'] : item['first_air_date'])
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

        def parse_date(value)
          return nil if value.to_s.strip.empty?

          Date.parse(value.to_s)
        rescue ArgumentError
          nil
        end

        def report_error(error, message)
          @speaker&.tell_error(error, message)
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

          Array(@fetcher.call(date_range: date_range, limit: limit))
            .filter_map { |record| build_entry(record) }
        rescue StandardError => e
          @speaker&.tell_error(e, 'Calendar IMDb fetch failed')
          []
        end

        def build_entry(record)
          {
            external_id: imdb_external_id(record),
            title: imdb_title(record),
            media_type: imdb_media_type(record),
            genres: imdb_list(record, :genres, :genre, %i[genres genres]),
            languages: imdb_list(record, :languages, :spoken_languages, :spokenLanguages),
            countries: imdb_list(record, :countries, :countries_of_origin, :countriesOfOrigin),
            rating: imdb_rating(record),
            release_date: imdb_release_date(record)
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

        def imdb_title(record)
          record_value(
            record,
            :title,
            :titleText,
            %i[titleText text],
            %i[title_text text],
            :originalTitleText,
            %i[originalTitleText text],
            %i[original_title_text text]
          )
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

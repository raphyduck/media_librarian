# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'date'

module MediaLibrarian
  module Services
    class CalendarFeedService < BaseService
      DEFAULT_WINDOW_DAYS = 30

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

        active_providers.flat_map { |provider| safe_fetch(provider, date_range, limit) }
                        .map { |entry| normalize_entry(entry, date_range) }
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

        source = entry[:source].to_s.strip
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

        Array(value).flat_map { |src| src.to_s.split(',') }
                    .map { |src| src.strip.downcase }
                    .reject(&:empty?)
      end

      def parse_date(value)
        case value
        when Date
          value
        when Time, DateTime
          value.to_date
        else
          Date.parse(value.to_s)
        end
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

      def default_providers
        return [] unless app&.config

        providers = []
        tmdb_config = app.config['tmdb']
        if tmdb_config.is_a?(Hash)
          providers << TmdbCalendarProvider.new(
            api_key: tmdb_config['api_key'],
            language: tmdb_config['language'] || tmdb_config['languages'],
            region: tmdb_config['region'],
            speaker: speaker
          )
        end
        providers.compact.select(&:available?)
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
    end
  end
end

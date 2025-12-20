# frozen_string_literal: true

require 'date'
require 'time'
require 'themoviedb'
require 'json'
require 'httparty'
require 'uri'
require_relative '../../../init/global'
require_relative '../../../lib/http_debug_logger'
require_relative '../../../lib/omdb_api'
require_relative '../../../lib/metadata'
require_relative '../../../lib/simple_speaker'
require 'trakt'

module MediaLibrarian
  module Services
    class CalendarFeedService < BaseService
      AuthenticationError = Class.new(StandardError)
      DEFAULT_WINDOW_DAYS = 365
      SOURCES_SEPARATOR = /[\s,|]+/.freeze

      def initialize(app: self.class.app, speaker: nil, file_system: nil, db: nil, providers: nil)
        super(app: app, speaker: speaker, file_system: file_system)
        @db = db || app&.db
        @providers = providers || default_providers
      end

      def self.enrich_entries(entries, app: self.app, speaker: nil, db: nil)
        new(app: app, speaker: speaker, db: db)&.send(:enrich_with_omdb, entries)
      rescue StandardError
        entries
      end

      def refresh(date_range: default_date_range, limit: 100, sources: nil)
        return [] unless calendar_table_available?

        normalized, stats = collect_entries(date_range, limit, normalize_sources(sources))
        normalized = enrich_with_omdb(normalized)
        stats = recompute_stats(stats, normalized)
        speaker.speak_up("Calendar feed collected #{normalized.length} items")
        persist_entries(normalized)
        speaker.speak_up("Calendar feed persisted #{normalized.length} items#{summary_suffix(stats)}")
        normalized
      end

      def search(title:, year: nil, type: nil)
        return [] unless calendar_table_available?
        return [] if title.to_s.strip.empty?

        date_range = year ? Date.new(year.to_i, 1, 1)..Date.new(year.to_i, 12, 31) : nil
        normalized = normalize_entries(provider_search(title: title, year: year, type: type), date_range)
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
        return [[], {}] if active_providers.empty?

        stats = Hash.new { |h, k| h[k] = { fetched: 0, retained: 0, location: nil } }

        collected = active_providers.flat_map do |provider|
          fetched = fetch_from_provider(provider, date_range, limit, stats)
          fetched
        end

        normalized = normalize_entries(collected, date_range).first(limit)

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
        return if date_range && release_date && !date_range.cover?(release_date)

        source = entry[:source].to_s.strip.downcase
        external_id = entry[:external_id].to_s.strip
        title = entry[:title].to_s.strip
        media_type = entry[:media_type].to_s.strip
        return if source.empty? || title.empty? || media_type.empty?

        ids = normalize_ids(entry[:ids] || entry['ids'])
        imdb_id = [entry[:imdb_id], ids['imdb'], ids[:imdb], external_id]
                  .map { |id| normalize_identifier(id) }
                  .find { |id| imdb_identifier?(id) }
        return unless imdb_id

        external_id = imdb_id if external_id.empty?
        ids = default_ids(ids, imdb_id)

        {
          source: source,
          external_id: external_id,
          imdb_id: imdb_id,
          title: title,
          media_type: media_type,
          genres: Array(entry[:genres]).compact.map(&:to_s),
          languages: Array(entry[:languages]).compact.map(&:to_s),
          countries: Array(entry[:countries]).compact.map(&:to_s),
          rating: entry[:rating] ? entry[:rating].to_f : nil,
          imdb_votes: entry[:imdb_votes].nil? ? nil : entry[:imdb_votes].to_i,
          poster_url: normalize_url(entry[:poster_url] || entry[:poster]),
          backdrop_url: normalize_url(entry[:backdrop_url] || entry[:backdrop]),
          synopsis: normalize_synopsis(entry),
          release_date: release_date,
          ids: ids
        }
      end

      def normalize_entries(entries, date_range)
        entries.map { |entry| normalize_entry(entry, date_range) }
               .compact
               .uniq { |entry| entry[:imdb_id] }
      end

      def normalize_sources(value)
        return nil if value.nil?

        tokens = Array(value).flat_map { |src| src.to_s.split(SOURCES_SEPARATOR) }
                              .map { |src| src.strip.downcase }
                              .map { |src| src == 'imdb' ? 'omdb' : src }
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

      def normalize_synopsis(entry)
        synopsis = %i[synopsis overview summary description plot tagline]
                   .lazy
                   .map { |key| entry[key] || entry[key.to_s] }
                   .find { |value| !value.to_s.strip.empty? }
        return nil unless synopsis

        text = synopsis.to_s.strip
        text.empty? ? nil : text
      end

      def normalize_ids(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, val), memo|
          memo[key.to_s] = val unless key.to_s.empty? || val.nil?
        end
      end

      def default_ids(ids, imdb_id)
        return ids unless ids.empty?
        return ids if imdb_id.to_s.empty?

        ids.merge('imdb' => imdb_id)
      end

      def persist_entries(entries)
        return [] if entries.empty?

        prepared = entries.filter_map { |entry| ensure_imdb_id(entry) }
        return [] if prepared.empty?

        db.insert_rows(:calendar_entries, prepared, true)
        prepared
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

      def provider_search(title:, year:, type:)
        select_providers(nil).flat_map do |provider|
          next [] unless provider.respond_to?(:search)

          Array(provider.search(title: title, year: year, type: type))
        end
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
        omdb_config = config['omdb']
        providers << omdb_provider(omdb_config) if omdb_config.is_a?(Hash)
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
          unless entry[:media_type] == 'movie'
            omdb_enrichment_debug("OMDb enrichment skipped for #{entry[:title] || entry[:external_id]} (media_type=#{entry[:media_type].inspect})")
            next
          end

          imdb_id = imdb_id_for(entry)
          omdb_enrichment_debug("OMDb enrichment fetching #{entry[:title] || entry[:external_id]} via IMDb #{imdb_id}") if imdb_id
          details = imdb_id ? omdb_details(api, imdb_id) : nil
          details = nil unless omdb_titles_match?(entry, details)

          unless details
            omdb_enrichment_debug("OMDb enrichment searching by title for #{entry[:title] || entry[:external_id]} (year=#{entry[:release_date]&.year || 'unknown'})")
            details = omdb_search_details(api, entry)
          end

          details = nil unless omdb_titles_match?(entry, details)

          unless details
            last_path = api.respond_to?(:last_request_path) ? api.last_request_path : nil
            last_payload = api.respond_to?(:last_response_body) ? truncate_payload(api.last_response_body) : nil
            omdb_enrichment_debug(
              "OMDb enrichment missing for #{entry[:title] || entry[:external_id]} (last_path=#{last_path}, last_payload=#{last_payload})"
            )
            next
          end

          entry[:ids] ||= {}
          entry[:ids]['imdb'] = details[:ids]&.[]('imdb') if details[:ids]
          entry[:rating] = details[:rating] unless details[:rating].nil?
          entry[:imdb_votes] = details[:imdb_votes] unless details[:imdb_votes].nil?
          entry[:poster_url] ||= details[:poster_url]
          entry[:backdrop_url] ||= details[:backdrop_url]
          entry[:release_date] ||= details[:release_date]

          entry[:genres] = details[:genres] if Array(entry[:genres]).empty? && details[:genres].is_a?(Array) && details[:genres].any?
          entry[:languages] = details[:languages] if Array(entry[:languages]).empty? && details[:languages].is_a?(Array) && details[:languages].any?
          entry[:countries] = details[:countries] if Array(entry[:countries]).empty? && details[:countries].is_a?(Array) && details[:countries].any?

          omdb_enrichment_debug(
            "OMDb enrichment applied to #{entry[:title] || entry[:external_id]} (imdb=#{entry[:ids]['imdb']}, rating=#{entry[:rating].inspect}, votes=#{entry[:imdb_votes].inspect})"
          )
        end

        entries.select do |entry|
          keep = entry[:media_type] != 'movie' || imdb_id_for(entry)
          omdb_enrichment_debug("OMDb enrichment removing #{entry[:title] || entry[:external_id]}: missing IMDb match") unless keep
          keep
        end
      end

      def recompute_stats(stats, entries)
        return stats unless stats

        counts = entries.group_by { |entry| entry[:source] }.transform_values(&:count)
        stats.each { |source, data| data[:retained] = counts[source] || 0 }
      end

      def omdb_search_details(api, entry)
        return nil unless entry[:title]

        year = entry[:release_date]&.year
        api.find_by_title(title: entry[:title], year: year, type: entry[:media_type]) if api.respond_to?(:find_by_title)
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
        candidates = []
        candidates << entry[:imdb_id]

        ids = entry[:ids]
        if ids.is_a?(Hash)
          candidates << ids['imdb']
          candidates << ids[:imdb]
          candidates.concat(ids.values.select { |value| imdb_identifier?(value) })
        end

        candidates << entry[:external_id] if imdb_identifier?(entry[:external_id])

        candidates.map { |id| normalize_identifier(id) }.find { |id| imdb_identifier?(id) }
      end

      def persist_imdb_id_for(entry)
        imdb_id_for(entry) || begin
          ids = entry[:ids]
          candidates = []
          candidates.concat(ids.values) if ids.is_a?(Hash)
          candidates << entry[:imdb_id]
          candidates << entry[:external_id]
          candidates.map { |id| normalize_identifier(id) }.find { |id| id && !id.empty? }
        end
      end

      def ensure_imdb_id(entry)
        imdb_id = persist_imdb_id_for(entry)
        if imdb_id.to_s.empty?
          speaker&.tell_error(StandardError.new('Missing IMDb ID'), "Calendar entry missing imdb_id: #{entry[:title] || entry[:external_id]}")
          return nil
        end

        entry[:ids] ||= {}
        entry[:ids]['imdb'] ||= imdb_id if imdb_identifier?(imdb_id)
        entry[:imdb_id] = imdb_id
        entry
      end

      def imdb_identifier?(value)
        value.to_s.match?(/\Att\d+/i)
      end

      def normalize_identifier(value)
        token = value.to_s.strip
        return '' if token.empty?

        digits = token.sub(/\A(?:imdb|tt)/i, '')
        return token unless digits.match?(/\A\d+\z/)

        "tt#{digits}"
      end

      def omdb_titles_match?(entry, details)
        return false unless details.is_a?(Hash)

        entry_imdb = normalize_identifier(entry[:imdb_id] || entry.dig(:ids, 'imdb'))
        detail_imdb = normalize_identifier(details.dig(:ids, 'imdb'))
        return true if imdb_identifier?(entry_imdb) && entry_imdb == detail_imdb

        clean_entry = normalized_title(entry[:title])
        clean_details = normalized_title(details[:title])
        return true if clean_entry.empty? || clean_details.empty?
        return true if clean_entry.start_with?(clean_details) || clean_details.start_with?(clean_entry)

        Metadata.match_titles(
          entry[:title].to_s,
          details[:title].to_s,
          entry[:release_date]&.year,
          details[:release_date]&.year,
          entry[:media_type] == 'show' ? 'shows' : 'movies'
        )
      end

      def normalized_title(value)
        value.to_s.downcase.gsub(/[^a-z0-9\s]/i, ' ').gsub(/[\s]+/, ' ').strip
      end

      def truncate_payload(payload)
        payload = payload.to_s
        return nil if payload.empty?

        payload.length > 200 ? "#{payload[0, 200]}...[truncated]" : payload
      end

      def omdb_enrichment_debug(message)
        return unless omdb_enrichment_debug?

        speaker&.speak_up(message)
      end

      def omdb_enrichment_debug?
        Env.debug?
      rescue StandardError
        false
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

        validated_token = ensure_trakt_token!(token)

        fetcher = trakt_calendar_client(
          client_id: client_id,
          client_secret: client_secret,
          account_id: account_id,
          token: validated_token
        )

        entries = []
        errors = []
        chunk_days = trakt_calendar_chunk_days
        current_date = start_date

        while current_date <= end_date && entries.size < limit
          days = [chunk_days, (end_date - current_date).to_i + 1].min

          movies = trakt_calendar_payload(:movies, fetcher, current_date, days)
          shows = trakt_calendar_payload(:shows, fetcher, current_date, days)

          parsed_movies, movie_error = parse_trakt_movies(movies)
          parsed_shows, show_error = parse_trakt_shows(shows)

          errors += [movie_error, show_error].compact
          entries = deduplicate_trakt_entries(entries + parsed_movies + parsed_shows)

          current_date += days
        end

        { entries: entries.first(limit), errors: errors }
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

      def trakt_calendar_chunk_days
        30
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
            movie = trakt_fetch(item, :movie)
            next unless movie.is_a?(Hash)

            release_date = parse_date(trakt_fetch(item, :released, :release_date, :first_aired))
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
            show = trakt_fetch(item, :show)
            next unless show.is_a?(Hash)

            release_date = parse_date(trakt_fetch(item, :first_aired) || trakt_fetch(trakt_fetch(item, :episode), :first_aired))
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
        normalized = normalize_trakt_payload(items)

        if normalized.empty?
          log_trakt_payload_error('Invalid Trakt payload format', context, items)
        else
          log_trakt_payload_error('Invalid Trakt payload format', context, items) if normalized.size < items.size
          [normalized, nil]
        end
      end

      def normalize_trakt_payload(payload)
        Array(payload).filter_map { |item| normalize_trakt_object(item) }
      end

      def normalize_trakt_object(value)
        return nil if value.nil?

        hash = case
               when value.is_a?(Hash)
                 value
               when value.respond_to?(:to_h)
                 begin
                   value.to_h
                 rescue StandardError
                   nil
                 end
               when value.respond_to?(:to_hash)
                 begin
                   value.to_hash
                 rescue StandardError
                   nil
                 end
               else
                attrs = %i[movie show released release_date first_aired episode ids title country genres language rating votes poster backdrop poster_url].each_with_object({}) do |key, memo|
                   memo[key] = value.public_send(key) if value.respond_to?(key)
                 end
                 return nil if attrs.empty?
                 attrs
               end

        return nil unless hash.is_a?(Hash)

        hash.each_with_object({}) do |(key, val), memo|
          memo[key] = case val
                      when Hash
                        normalize_trakt_object(val) || val
                      when Array
                        val.map { |item| normalize_trakt_object(item) || item }
                      else
                        normalize_trakt_object(val) || val
                      end
        end
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
        title = trakt_fetch(record, :title).to_s
        return if external_id.to_s.empty? || title.empty?

        {
          external_id: external_id,
          title: title,
          media_type: media_type,
          genres: Array(trakt_fetch(record, :genres)).compact.map(&:to_s),
          languages: wrap_string(trakt_fetch(record, :language)),
          countries: wrap_string(trakt_fetch(record, :country)),
          rating: safe_float(trakt_fetch(record, :rating)),
          imdb_votes: nil,
          poster_url: trakt_image(record, %i[images poster full], %i[images poster medium], %i[poster], %i[poster_url]),
          backdrop_url: trakt_image(record, %i[images fanart full], %i[images backdrop full], %i[fanart], %i[backdrop]),
          synopsis: trakt_fetch(record, :overview),
          release_date: release_date,
          ids: ids
        }
      end

      def deduplicate_trakt_entries(entries)
        entries.each_with_object({}) do |entry, memo|
          key = [entry[:media_type], entry[:external_id]]
          memo[key] ||= entry
        end.values
      end

      def trakt_fetch(record, *keys)
        return nil unless record

        keys.each do |key|
          candidates = [key, key.to_s, key.to_sym].uniq
          candidates.each do |candidate|
            next unless record.respond_to?(:[])

            begin
              value = record[candidate]
            rescue StandardError
              next
            end

            return value unless value.nil?
          end

          return record.public_send(key) if record.respond_to?(key)
          return record.public_send(key.to_s) if record.respond_to?(key.to_s)
        end

        nil
      end

      def trakt_external_id(ids)
        ids['imdb'] || ids['slug'] || ids['tmdb']&.to_s || ids['tvdb']&.to_s || ids['trakt']&.to_s
      end

      def trakt_ids(record)
        raw_ids = normalize_trakt_object(trakt_fetch(record, :ids)) || {}
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

        def search(title:, year: nil, type: nil)
          return [] unless available?
          kinds = Array(normalize_kind(type))
          kinds = %i[movie tv] if kinds.empty?

          kinds.flat_map { |kind| search_titles(kind, title, year) }
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

        def search_titles(kind, title, year)
          payload = fetch_page("/search/#{kind == :tv ? 'tv' : 'movie'}", kind, 1, search_params(kind, title, year))
          return [] unless payload

          Array(payload['results']).filter_map do |item|
            release_date = release_from(item, kind)
            details = fetch_details(kind, value_from(item, :id))
            build_entry(details, kind, release_date) if details
          end
        end

        def fetch_page(path, kind, page, params = {})
          @last_request_path = path
          params = { page: page }.merge(params || {}).compact

          if page.to_i == 1
            begin
              case kind
              when :movie
                if path == '/movie/upcoming' && client.const_defined?(:Movie) && client::Movie.respond_to?(:upcoming)
                  return log_tmdb_request(path, params, client::Movie.upcoming)
                end
                if path == '/movie/now_playing' && client.const_defined?(:Movie) && client::Movie.respond_to?(:now_playing)
                  return log_tmdb_request(path, params, client::Movie.now_playing)
                end
              when :tv
                if path == '/tv/on_the_air' && client.const_defined?(:TV) && client::TV.respond_to?(:on_the_air)
                  return log_tmdb_request(path, params, client::TV.on_the_air)
                end
                if path == '/tv/airing_today' && client.const_defined?(:TV) && client::TV.respond_to?(:airing_today)
                  return log_tmdb_request(path, params, client::TV.airing_today)
                end
              end
            rescue ArgumentError
              nil
            end
          end

          if client.const_defined?(:Api) && client::Api.respond_to?(:request)
            return log_tmdb_request(path, params, client::Api.request(path, params))
          end

          http_request(path, params)
        rescue StandardError => e
          report_error(e, "Calendar TMDB fetch failed for #{path}")
          nil
        end

        def http_request(path, params)
          query = params.merge(api_key: @api_key, language: language, region: region).compact
          response = HTTParty.get("https://api.themoviedb.org/3#{path}", query: query)
          log_tmdb_request(path, query, response)
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

        def log_tmdb_request(path, params, response)
          HttpDebugLogger.log(
            provider: 'TMDb',
            method: 'GET',
            url: tmdb_url(path, params),
            payload: params,
            response: response,
            speaker: @speaker
          )
          response
        end

        def tmdb_url(path, params)
          base = "https://api.themoviedb.org/3#{path}"
          return base if params.nil? || params.empty?

          "#{base}?#{URI.encode_www_form(params)}"
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

        def search_params(kind, title, year)
          params = { query: title }
          params[:year] = year if kind == :movie && year
          params[:first_air_date_year] = year if kind == :tv && year
          params
        end

        def normalize_kind(type)
          value = type.to_s.downcase
          return :tv if value.start_with?('tv') || value.include?('show')
          return :movie if value == 'movie' || value == 'film'

          nil
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
          (kind == :movie ? client::Movie : client::TV).detail(id, append_to_response: 'external_ids')
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
              synopsis: details['overview'],
              release_date: release_date,
              ids: tmdb_ids(details)
            }
          end

        def tmdb_ids(details)
          ids = { 'tmdb' => details['id'] }
          imdb_id = details['imdb_id'].to_s
          imdb_id = details.dig('external_ids', 'imdb_id').to_s if imdb_id.empty?
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

        def search(title:, year: nil, type: nil)
          return [] unless available?

          entry = omdb_client.find_by_title(title: title, year: year, type: omdb_type(type))
          entry ? [entry] : []
        rescue StandardError => e
          @speaker&.tell_error(e, 'Calendar OMDb search failed')
          []
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

          api = omdb_client
          @fetcher = lambda do |date_range:, limit:|
            api.calendar(date_range: date_range, limit: limit)
          end
        end

        def omdb_client
          @api_client ||= OmdbApi.new(api_key: @api_key, base_url: @base_url, speaker: @speaker)
        end

        def omdb_type(value)
          type = value.to_s.downcase
          return 'series' if type.include?('show') || type == 'series'

          type.empty? ? 'movie' : type
        end

        def api_last_request_path(fetcher)
          return unless defined?(@api_client)

          @api_client.last_request_path if fetcher && @api_client.respond_to?(:last_request_path)
        end

        def normalize_entry(entry, date_range)
          release_date = parse_date(entry[:release_date] || entry['release_date'] || entry['Released'] || entry['DVD'])
          year = release_date&.year || parse_year(fetch_value(entry, :year, :Year))
          return unless year

          year_match = date_range.any? { |date| date.respond_to?(:year) && date.year == year }
          release_date ||= year_match ? parse_date(date_range.first) : Date.new(year, 1, 1)
          return unless release_date && (date_range.cover?(release_date) || year_match)

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
            synopsis: fetch_value(entry, :synopsis, :Plot, :plot),
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

        def parse_year(value)
          year = value.to_s[/\d{4}/]
          year ? year.to_i : nil
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

        def search(title:, year: nil, type: nil)
          return [] unless available?
          return [] unless @fetcher&.respond_to?(:search)

          date_range = search_date_range(year)
          Array(@fetcher.search(title: title, year: year, type: type))
            .filter_map { |entry| normalize_entry(entry, date_range) }
        rescue StandardError => e
          @speaker&.tell_error(e, 'Calendar Trakt search failed')
          []
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
          return unless release_date && (!date_range || date_range.cover?(release_date))

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

        def search_date_range(year)
          return nil unless year

          date = Date.new(year.to_i, 1, 1)
          date..date.next_year(1).prev_day
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

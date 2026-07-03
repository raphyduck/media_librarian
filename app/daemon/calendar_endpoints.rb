# frozen_string_literal: true

# Calendar and collection HTTP endpoints for the daemon control server: the
# request handlers plus their payload normalizers. Reopens Daemon's singleton
# class so these methods stay byte-for-byte identical to their prior inline
# definitions; extracted purely to shrink app/daemon.rb. Zeitwerk is told to
# ignore this file (see Application#setup_loader) because it reopens Daemon
# rather than defining a Daemon::CalendarEndpoints constant.

class Daemon
  class << self
    def handle_calendar_request(req, res)
      return method_not_allowed(res, 'GET') unless req.request_method == 'GET'

      filters = {
        type: req.query['type'],
        genres: normalize_list_param(req.query['genres']),
        imdb_min: req.query['imdb_min'],
        imdb_max: req.query['imdb_max'],
        imdb_votes_min: req.query['imdb_votes_min'],
        imdb_votes_max: req.query['imdb_votes_max'],
        language: req.query['language'],
        country: req.query['country'],
        title: req.query['title'],
        downloaded: req.query['downloaded'],
        interest: req.query['interest'],
        sort: req.query['sort'],
        start_date: calendar_start_date(req.query),
        end_date: calendar_end_date(req.query),
        page: req.query['page'],
        per_page: req.query['per_page']
      }

      calendar = Calendar.new(app: app)
      json_response(res, body: calendar.entries(filters))
    rescue StandardError => e
      error_response(res, status: 500, message: e.message)
    end

    def handle_calendar_search_request(req, res)
      return method_not_allowed(res, 'GET') unless req.request_method == 'GET'

      title = req.query['title'].to_s.strip
      return error_response(res, status: 400, message: 'missing_title') if title.empty?

      year = req.query['year'].to_s.strip
      year = year.empty? ? nil : year.to_i
      type = req.query['type'].to_s.strip
      type = nil if type.empty?
      sources = normalize_list_param(req.query['sources'])
                .map { |source| source.to_s.strip.downcase }
                .reject(&:empty?)
                .map { |source| source == 'imdb' ? 'omdb' : source }
      limit = clamp_positive_integer(req.query['limit'], default: 50, max: 50)

      service = MediaLibrarian::Services::CalendarFeedService.new(app: app)
      entries = service.search(title: title, year: year, type: type, persist: false)
      entries = entries.select { |entry| sources.include?(entry[:source].to_s.downcase) } if sources.any?
      entries = entries.first(limit)

      json_response(res, body: { 'entries' => entries })
    rescue StandardError => e
      error_response(res, status: 500, message: e.message)
    end

    def handle_calendar_import_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'

      payload = parse_payload(req)
      entry, error = normalize_calendar_import_payload(payload)
      return error_response(res, status: 422, message: error) unless entry

      service = MediaLibrarian::Services::CalendarFeedService.new(app: app)
      persisted = service.persist_entry(entry)
      return error_response(res, status: 422, message: 'invalid_entry') unless persisted

      watchlist_status = 'skipped'
      if truthy?(payload['watchlist'] || payload['interest'] || payload['add_to_watchlist'])
        WatchlistStore.upsert([{
          imdb_id: persisted[:imdb_id],
          title: persisted[:title],
          type: Utils.regularise_media_type((persisted[:media_type] || 'movies').to_s)
        }])
        watchlist_status = 'added'
      end

      Calendar.clear_cache
      json_response(res, body: { 'calendar' => 'imported', 'watchlist' => watchlist_status })
    rescue JSON::ParserError => e
      error_response(res, status: 422, message: e.message)
    rescue StandardError => e
      error_response(res, status: 500, message: e.message)
    end

    def handle_collection_request(req, res)
      return method_not_allowed(res, 'GET') unless req.request_method == 'GET'

      params = normalize_collection_params(req.query)
      result = collection_repository.paginated_entries(**params)

      json_response(
        res,
        body: {
          'entries' => result[:entries],
          'type' => params[:type],
          'pagination' => {
            'page' => result[:page] || params[:page],
            'per_page' => result[:per_page] || params[:per_page],
            'total' => result[:total]
          }
        }
      )
    rescue StandardError => e
      error_response(res, status: 500, message: e.message)
    end

    def handle_calendar_refresh_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'

      payload = parse_payload(req)
      args = ['calendar', 'refresh_feed']
      args += %w[days limit].filter_map { |key| payload[key] && "--#{key}=#{payload[key]}" }

      sources = payload['sources']
      args << "--sources=#{Array(sources).join(',')}" if sources

      job = enqueue(args: args, parent_thread: nil)
      json_response(res, body: { 'job' => job&.to_h })
    rescue StandardError => e
      error_response(res, status: 500, message: e.message)
    end

    def normalize_calendar_import_payload(payload)
      return [nil, 'invalid_payload'] unless payload.is_a?(Hash)

      imdb_id = MediaLibrarian::ImdbIdentifier.normalize_identifier(payload['imdb_id'] || payload.dig('ids', 'imdb') || payload.dig('ids', 'imdb_id'))
      return [nil, 'missing_imdb_id'] unless MediaLibrarian::ImdbIdentifier.imdb_identifier?(imdb_id)

      title = payload['title'].to_s.strip
      return [nil, 'missing_title'] if title.empty?

      media_type = normalize_calendar_media_type(payload['type'] || payload['media_type'])
      return [nil, 'missing_type'] unless media_type

      ids = normalize_calendar_ids(payload['ids'])
      return [nil, 'invalid_ids'] if ids == :invalid
      ids['imdb'] ||= imdb_id

      release_date_raw = payload['release_date']
      release_date = normalize_calendar_date(release_date_raw)
      return [nil, 'invalid_release_date'] if release_date_raw && release_date.nil?

      synopsis = normalize_calendar_text(payload['synopsis'])
      poster_url = normalize_calendar_url(payload['poster_url'] || payload['poster'])
      backdrop_url = normalize_calendar_url(payload['backdrop_url'] || payload['backdrop'])

      [
        {
          source: normalize_calendar_text(payload['source']) || 'manual',
          external_id: normalize_calendar_text(payload['external_id'] || payload['id']) || imdb_id,
          imdb_id: imdb_id,
          title: title,
          media_type: media_type,
          genres: normalize_calendar_list(payload['genres']),
          languages: normalize_calendar_list(payload['languages']),
          countries: normalize_calendar_list(payload['countries']),
          rating: normalize_calendar_float(payload['rating'] || payload['imdb_rating']),
          imdb_votes: normalize_calendar_integer(payload['imdb_votes']),
          poster_url: poster_url,
          backdrop_url: backdrop_url,
          synopsis: synopsis,
          release_date: release_date,
          ids: ids
        },
        nil
      ]
    end

    def normalize_calendar_media_type(value)
      case value.to_s.downcase
      when 'movie', 'movies', 'film', 'films'
        'movie'
      when 'show', 'shows', 'tv', 'series'
        'show'
      else
        nil
      end
    end

    def normalize_calendar_ids(value)
      return {} if value.nil?
      return :invalid unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, val), memo|
        key = key.to_s.strip
        next if key.empty? || val.nil?

        memo[key] = val
      end
    end

    def normalize_calendar_list(value)
      case value
      when Array
        value.map { |entry| entry.to_s.strip }.reject(&:empty?)
      when String
        value.split(',').map { |entry| entry.to_s.strip }.reject(&:empty?)
      else
        []
      end
    end

    def normalize_calendar_text(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def normalize_calendar_url(value)
      normalize_calendar_text(value)
    end

    def normalize_calendar_date(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def normalize_calendar_float(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_calendar_integer(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end

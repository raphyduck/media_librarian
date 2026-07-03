# frozen_string_literal: true

# Music HTTP endpoints for the daemon control server: search, download,
# CSV import, organize, and result serialization. Reopens Daemon's singleton
# class so these methods stay byte-for-byte identical to their prior inline
# definitions; extracted purely to shrink app/daemon.rb. Zeitwerk is told to
# ignore this file (see Application#setup_loader) because it reopens Daemon
# rather than defining a Daemon::MusicEndpoints constant.

class Daemon
  class << self
    def handle_music_search_request(req, res)
      return method_not_allowed(res, 'GET') unless req.request_method == 'GET'

      query = req.query['query'].to_s.strip
      query = req.query['keyword'].to_s.strip if query.empty?
      # A blank query returns just the quality options, used by the UI to populate
      # its dropdown before the first real search.
      return json_response(res, body: { 'results' => [], 'qualities' => MusicQuality.options }) if query.empty?

      quality = req.query['quality'].to_s.strip
      return error_response(res, status: 422, message: 'invalid_quality') unless quality.empty? || MusicQuality.valid?(quality)

      limit = clamp_positive_integer(req.query['limit'], default: 50, max: 100)
      results = MusicSearch.search(keyword: query, quality: quality, limit: limit)
      json_response(res, body: {
        'results' => results.map { |torrent| serialize_music_result(torrent) },
        'qualities' => MusicQuality.options
      })
    rescue StandardError => e
      error_response(res, status: 500, message: e.message)
    end

    def handle_music_download_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'

      payload = parse_payload(req)
      name = payload['name'].to_s.strip
      link = payload['link'].to_s.strip
      torrent_link = payload['torrent_link'].to_s.strip
      return error_response(res, status: 422, message: 'missing_name') if name.empty?
      return error_response(res, status: 422, message: 'missing_link') if link.empty? && torrent_link.empty?

      quality = payload['quality'].to_s.strip
      return error_response(res, status: 422, message: 'invalid_quality') unless quality.empty? || MusicQuality.valid?(quality)

      result = MusicSearch.queue_download(
        name: name, link: link, torrent_link: torrent_link,
        tracker: payload['tracker'], size: payload['size'], seeders: payload['seeders'],
        added: payload['added'], quality: quality
      )
      return error_response(res, status: 422, message: result['error']) if result['error']

      json_response(res, body: result)
    rescue JSON::ParserError => e
      error_response(res, status: 422, message: e.message)
    rescue StandardError => e
      error_response(res, status: 500, message: e.message)
    end

    def handle_music_import_csv_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'

      payload = parse_payload(req)
      quality = payload['quality'].to_s.strip
      return error_response(res, status: 422, message: 'invalid_quality') unless quality.empty? || MusicQuality.valid?(quality)

      csv_content = payload['csv_content']
      return error_response(res, status: 422, message: 'missing_csv') if csv_content.nil? && payload['csv_path'].nil?

      if truthy?(payload['async'])
        args = build_music_import_csv_args(payload, quality)
        job = enqueue(args: args, parent_thread: nil, task: 'music_import_csv')
        return json_response(res, body: { 'job_id' => job&.id, 'job' => job&.to_h })
      end

      content = csv_content.to_s
      return error_response(res, status: 422, message: 'empty_csv') if content.strip.empty?

      result = MusicSearch.import_csv(csv_content: content, quality: quality, detailed: true)
      json_response(res, body: result)
    rescue JSON::ParserError => e
      error_response(res, status: 422, message: e.message)
    rescue StandardError => e
      error_response(res, status: 422, message: e.message)
    end

    def build_music_import_csv_args(payload, quality)
      csv_content = payload['csv_content']
      csv_path = payload['csv_path']
      raise ArgumentError, 'missing_csv' if csv_content.nil? && csv_path.nil?

      args = ['music', 'import_csv']
      args << "--csv_path=#{resolve_watchlist_csv_path(csv_content, csv_path)}"
      args << '--detailed=1'
      args << "--quality=#{quality}" unless quality.empty?
      args << '--debug=1' if truthy?(payload['debug']) || payload['debug'] == 1
      args
    end

    def handle_music_organize_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'

      payload = parse_payload(req) rescue {}
      source = payload['source'].to_s.strip
      if truthy?(payload['async'])
        args = ['music', 'organize']
        args << "--source=#{source}" unless source.empty?
        job = enqueue(args: args, parent_thread: nil, task: 'music_organize')
        return json_response(res, body: { 'job_id' => job&.id, 'job' => job&.to_h })
      end

      result = MusicLibrary.organize(source: source)
      json_response(res, body: result)
    rescue StandardError => e
      error_response(res, status: 500, message: e.message)
    end

    def serialize_music_result(torrent)
      {
        'name' => torrent[:name].to_s,
        'size' => torrent[:size].to_i,
        'seeders' => torrent[:seeders].to_i,
        'leechers' => torrent[:leechers].to_i,
        'tracker' => torrent[:tracker].to_s,
        'link' => torrent[:link].to_s,
        'torrent_link' => torrent[:torrent_link].to_s,
        'added' => torrent[:added].to_s,
        'quality' => torrent[:quality].to_s
      }
    end
  end
end

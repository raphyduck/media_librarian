# frozen_string_literal: true

require 'csv'
require 'uri'
require 'ipaddr'
require 'resolv'

# Music torrent search.
#
# Music is handled as a first-class media category ('music') that flows through
# the existing torrent download pipeline (torrents table -> deluge -> move to the
# music destination) but bypasses the video metadata identification (IMDB/TMDB)
# which does not apply to audio releases.
#
# Two entry points:
#   * search           - interactive keyword search returning quality-filtered results
#   * import_csv        - one free-text query per line, auto-queueing the best match
class MusicSearch
  include MediaLibrarian::AppContainerSupport

  CATEGORY = 'music'

  # Interactive search: returns an array of torrent result hashes ordered by
  # seeders (descending), keeping only releases matching the requested quality.
  def self.search(keyword:, quality: nil, sources: nil, limit: 50, filter_dead: 1)
    keyword = sanitize_keyword(keyword)
    return [] if keyword.empty?

    svc = tracker_query_service
    results = []
    svc.get_trackers(sources || default_sources).each do |tracker|
      keyword_with_site = (keyword + svc.get_site_keywords(tracker, CATEGORY)).strip
      tracker_results = svc.launch_search(tracker, CATEGORY, keyword_with_site)
      if (tracker_results.nil? || tracker_results.empty?) && keyword_with_site != keyword
        tracker_results = svc.launch_search(tracker, CATEGORY, keyword)
      end
      results += Array(tracker_results)
    end

    if filter_dead.to_i > 0
      results.select! { |torrent| torrent[:seeders].to_i >= filter_dead.to_i }
    end
    results = MusicQuality.filter(results, quality)
    results = dedupe_by_name(results)
    results.sort_by! { |torrent| -torrent[:seeders].to_i }
    results = results.first(limit.to_i) if limit.to_i > 0
    results.map { |torrent| torrent.merge(:quality => quality.to_s) }
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    []
  end

  # Queue a chosen torrent (from a search result) for download into the music
  # destination. Accepts the fields returned by .search.
  def self.queue_download(name:, link:, tracker:, size: nil, seeders: nil, torrent_link: nil, added: nil, quality: nil)
    name = name.to_s.strip
    raise ArgumentError, 'missing_name' if name.empty?
    raise ArgumentError, 'missing_link' if link.to_s.strip.empty? && torrent_link.to_s.strip.empty?
    # These links are fetched server-side later; reject ones pointing at
    # loopback/link-local hosts (SSRF into local services / cloud metadata).
    [link, torrent_link].each do |candidate|
      raise ArgumentError, 'unsafe_link' unless safe_download_link?(candidate)
    end

    torrent = {
      :name => name,
      :identifier => "music:#{name}",
      :link => link.to_s,
      :torrent_link => torrent_link.to_s,
      :tracker => tracker.to_s,
      :size => size,
      :seeders => seeders,
      :added => (added.to_s.empty? ? Time.now.to_s : added.to_s),
      :category => CATEGORY,
      :move_completed => music_staging,
      :whitelisted_extensions => FileUtils.get_valid_extensions(CATEGORY),
      :music_quality => quality.to_s
    }
    TorrentSearch.torrent_download(torrent, 1, 1, [], CATEGORY)
    { 'queued' => name }
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    { 'error' => e.message }
  end

  # Number of queued / not-found titles echoed back in the import report. The
  # totals are always exact; only the sample lists are capped to keep the job
  # payload reasonable for very large CSVs.
  IMPORT_REPORT_SAMPLE = 200

  # CSV import: one album query per row (structured "Artiste,Album" export) or
  # one free-text query per line. For each, run a music search and auto-queue
  # the best matching result for the requested quality. When a structured row's
  # album is not found, retry the search with the artist alone (once per artist)
  # to catch a discography, skipping various-artists/compilation buckets.
  def self.import_csv(csv_path: nil, csv_content: nil, quality: nil, limit: 50, detailed: false)
    # Declared before extract_entries so the report is available even if a
    # failure happens before or during the loop.
    queued = []
    not_found = []
    entries = extract_entries(csv_path: csv_path, csv_content: csv_content)
    total = entries.size
    speaker = app.respond_to?(:speaker) ? app.speaker : nil
    speaker&.speak_up("music import_csv: starting (total #{total}, quality '#{MusicQuality.label(quality)}')", 0)

    progress = {
      'processed' => 0, 'queued' => 0, 'not_found' => 0, 'total' => total,
      'current_query' => nil, 'queued_titles' => [], 'not_found_entries' => []
    }
    jid = Thread.current[:jid]
    update_progress = lambda do |force = false|
      return unless jid && defined?(Daemon) && Daemon.respond_to?(:update_job_progress, true)
      return unless force || (progress['processed'].positive? && (progress['processed'] % 5).zero?)

      Daemon.send(:update_job_progress, jid, progress.dup)
    end
    update_progress.call(true)

    # Artists whose album-less fallback search has already run, so an entire
    # unfound discography is not re-searched (and re-queued) once per album.
    fallback_done = {}

    entries.each do |entry|
      query = entry['query']
      progress['processed'] += 1
      progress['current_query'] = query
      begin
        results = search(keyword: query, quality: quality, limit: limit)
        best = results.first

        if best.nil?
          fallback = artist_fallback(entry['artist'], query)
          if fallback && !fallback_done[fallback.downcase]
            fallback_done[fallback.downcase] = true
            speaker&.speak_up("music import_csv: #{progress['processed']}/#{total} '#{query}' -> no album match, retrying artist '#{fallback}'", 0)
            results = search(keyword: fallback, quality: quality, limit: limit)
            best = results.first
          end
        end

        if best.nil?
          not_found << query
          progress['not_found'] += 1
          progress['not_found_entries'] = not_found.first(IMPORT_REPORT_SAMPLE)
          speaker&.speak_up("music import_csv: #{progress['processed']}/#{total} '#{query}' -> no result", 0)
        else
          queue_download(
            name: best[:name], link: best[:link], tracker: best[:tracker],
            size: best[:size], seeders: best[:seeders], torrent_link: best[:torrent_link],
            added: best[:added], quality: quality
          )
          queued << best[:name]
          progress['queued'] += 1
          progress['queued_titles'] = queued.first(IMPORT_REPORT_SAMPLE)
          speaker&.speak_up("music import_csv: #{progress['processed']}/#{total} '#{query}' -> queued '#{best[:name]}'", 0)
        end
      rescue StandardError => e
        # One failing query must never abort the whole import (and wipe the
        # report): record it as not-found, log it, and carry on.
        not_found << query
        progress['not_found'] += 1
        progress['not_found_entries'] = not_found.first(IMPORT_REPORT_SAMPLE)
        app.speaker.tell_error(e, "music import_csv query '#{query}'") rescue nil
      end
      update_progress.call
    end

    update_progress.call(true)
    speaker&.speak_up("music import_csv: done (queued #{queued.size}, not found #{not_found.size})", 0)
    import_csv_report(queued, not_found, detailed)
  rescue => e
    # Even on an unexpected top-level failure, return what was accumulated so the
    # UI shows a real report instead of a blank "failed" with zeroes.
    app.speaker.tell_error(e, Utils.arguments_dump(binding), 0) rescue nil
    import_csv_report(queued, not_found, detailed)
  end

  def self.import_csv_report(queued, not_found, detailed)
    return queued.size unless detailed

    {
      'total_queued' => queued.size, 'queued_titles' => queued.first(IMPORT_REPORT_SAMPLE),
      'not_found' => not_found.size, 'not_found_entries' => not_found.first(IMPORT_REPORT_SAMPLE)
    }
  end

  def self.qualities
    MusicQuality.options
  end

  def self.music_destination
    configured = (app.config['music'] && app.config['music']['destination']).to_s.strip
    File.expand_path(configured.empty? ? DEFAULT_MUSIC_DESTINATION : configured)
  rescue
    DEFAULT_MUSIC_DESTINATION
  end

  # Staging folder where Deluge drops completed music torrents. Like movies and
  # shows, music must land in a staging area first so the Execute plugin can
  # trigger `library handle_completed_download`, which then files the release
  # into the final library (music_destination). Passing music_destination here
  # would make Deluge dump loose files straight into the library, bypassing that
  # pipeline. Configurable via music.staging; falls back to music_destination
  # (previous behaviour) when unset.
  def self.music_staging
    configured = (app.config['music'] && app.config['music']['staging']).to_s.strip
    return music_destination if configured.empty?

    File.expand_path(configured)
  rescue
    music_destination
  end

  # Trackers to use when a search/import does not explicitly pass 'sources'.
  # Configured via music.sources (array of tracker names, e.g. ['c411', 'torr9']).
  # Kept separate from other content types because not every configured tracker
  # indexes music: some return zero results (no audio category at all) and
  # others may be temporarily broken independently of this feature. Falls back
  # to every configured tracker (previous behaviour) when unset.
  def self.default_sources
    configured = app.config['music'] && app.config['music']['sources']
    Array(configured).map(&:to_s).map(&:strip).reject(&:empty?)
  rescue
    []
  end

  def self.sanitize_keyword(keyword)
    keyword.to_s.gsub(/[\(\)\:\'\"!\?\;\,]/, '').strip
  end

  def self.dedupe_by_name(results)
    seen = {}
    Array(results).each do |torrent|
      key = torrent[:name].to_s
      seen[key] = torrent if seen[key].nil? || torrent[:seeders].to_i > seen[key][:seeders].to_i
    end
    seen.values
  end

  def self.extract_queries(csv_path: nil, csv_content: nil)
    extract_entries(csv_path: csv_path, csv_content: csv_content).map { |entry| entry['query'] }
  end

  # Like extract_queries, but returns one entry per row: { 'query' => ...,
  # 'artist' => ... }. For a structured CSV the artist is kept separately so an
  # unfound album can be retried with the artist alone; free-text lines have no
  # separable artist, so 'artist' is nil.
  def self.extract_entries(csv_path: nil, csv_content: nil)
    content = if !csv_content.to_s.empty?
                csv_content.to_s
              elsif csv_path.to_s.strip != ''
                raise ArgumentError, "CSV file not found: #{csv_path}" unless File.file?(csv_path)

                File.read(csv_path)
              else
                raise ArgumentError, 'missing_csv'
              end
    # The CSV is UTF-8 (accented artist/album names are common). Retag/scrub so
    # a daemon running under a non-UTF-8 locale does not choke on the first
    # accented byte when splitting or CSV-parsing the content.
    content = content.to_s.dup.force_encoding('UTF-8').scrub
    structured = structured_entries(content)
    return structured if structured

    lines = content.lines.map(&:strip).reject(&:empty?)
    lines.shift if lines.first && lines.first.downcase.delete('"').strip == 'query'
    lines.map { |line| line.sub(/\A"(.*)"\z/, '\1').strip }.reject(&:empty?)
         .map { |query| { 'query' => query, 'artist' => nil } }
  end

  # Column headers a structured export (e.g. a Spotify/library dump
  # "Artiste,Album,Année,Titres") may use for the artist and album fields.
  STRUCTURED_ARTIST_HEADERS = %w[artiste artist artists interprete interprète].freeze
  STRUCTURED_ALBUM_HEADERS = %w[album albums disque].freeze

  # When the CSV carries a header row with recognizable artist and/or album
  # columns, return one entry per row — { 'query' => "<artist> <album>",
  # 'artist' => "<artist>" } — keeping the artist alone so an unfound album can
  # be retried with just the artist. Returns nil when the content is not such a
  # structured CSV, so the caller falls back to the one-free-text-query-per-line
  # format. Quoted fields, embedded commas/newlines and a trailing quantity
  # column (e.g. number of tracks) are handled by the CSV parser rather than
  # choking the naive line splitter.
  def self.structured_entries(content)
    first_line = content.to_s.lines.first.to_s
    separator = first_line.count(';') > first_line.count(',') ? ';' : ','
    rows = CSV.parse(content, headers: true, col_sep: separator)
    return nil if rows.headers.nil?

    artist_key = rows.headers.find { |h| STRUCTURED_ARTIST_HEADERS.include?(h.to_s.strip.downcase) }
    album_key = rows.headers.find { |h| STRUCTURED_ALBUM_HEADERS.include?(h.to_s.strip.downcase) }
    return nil unless artist_key || album_key

    seen = {}
    rows.each_with_object([]) do |row, entries|
      artist = artist_key ? row[artist_key].to_s.strip : ''
      album = album_key ? row[album_key].to_s.strip : ''
      query = [artist, album].reject(&:empty?).join(' ')
      next if query.empty? || seen[query]

      seen[query] = true
      entries << { 'query' => query, 'artist' => (artist.empty? ? nil : artist) }
    end
  rescue CSV::MalformedCSVError, ArgumentError, EncodingError
    nil
  end

  # Artist-column values that are not a single real artist, so the not-found
  # fallback must not grab "their" discography (compilations / various-artists
  # buckets). Matched case-insensitively against the trimmed artist name.
  NON_ARTIST_NAMES = [
    'various', 'various artist', 'various artists', 'va', 'v.a.', 'v/a',
    'compilation', 'compilations', 'divers', 'artistes divers',
    'multi-interprètes', 'multi interprètes', 'multinterprètes',
    'unknown', 'unknown artist', 'soundtrack', 'original soundtrack',
    'ost', 'o.s.t.', 'cast', 'original cast', 'traditional'
  ].freeze

  # The artist to retry an unfound album with, or nil when there is no usable
  # artist: absent, identical to the album-query already tried, or a
  # various-artists/compilation-style bucket rather than a real performer.
  def self.artist_fallback(artist, full_query)
    name = artist.to_s.strip
    return nil if name.empty? || name.casecmp?(full_query.to_s.strip)
    return nil if non_artist?(name)

    name
  end

  def self.non_artist?(name)
    normalized = name.to_s.downcase.strip.gsub(/\s+/, ' ')
    NON_ARTIST_NAMES.include?(normalized) || normalized.start_with?('various')
  end

  # Loopback / link-local (incl. cloud metadata 169.254.169.254) / unspecified
  # ranges that a server-side fetch must never reach. RFC1918 LAN ranges are
  # intentionally allowed so private/self-hosted trackers keep working.
  BLOCKED_ADDRESS_RANGES = [
    IPAddr.new('0.0.0.0/8'), IPAddr.new('127.0.0.0/8'), IPAddr.new('169.254.0.0/16'),
    IPAddr.new('::1/128'), IPAddr.new('fe80::/10'), IPAddr.new('::/128')
  ].freeze

  # A blank/absent link is fine (nothing is fetched); otherwise only http(s) and
  # magnet links pointing at non-loopback/non-link-local hosts are accepted.
  def self.safe_download_link?(link)
    link = link.to_s.strip
    return true if link.empty?
    return true if link.downcase.start_with?('magnet:')

    uri = URI.parse(link) rescue nil
    return false unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
    return false if uri.host.downcase == 'localhost'

    addresses = resolve_addresses(uri.host)
    addresses.none? { |ip| BLOCKED_ADDRESS_RANGES.any? { |range| range.include?(ip) } }
  rescue StandardError
    false
  end

  def self.resolve_addresses(host)
    literal = (IPAddr.new(host) rescue nil)
    return [literal] if literal

    Resolv.getaddresses(host).filter_map { |address| IPAddr.new(address) rescue nil }
  rescue StandardError
    []
  end

  def self.tracker_query_service
    MediaLibrarian::Services::TrackerQueryService.new(app: app)
  end
end

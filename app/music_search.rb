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

  # Un release avec trop peu de seeders meurt souvent avant la fin du
  # téléchargement ; l'import automatique exige un minimum. Surchargeable via
  # conf.yml : music.min_seeders
  DEFAULT_MIN_SEEDERS_IMPORT = 3

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
    # Declared up front so the report is available even if a failure happens
    # before or during processing.
    queued = []              # releases queued on a tracker (async -> Deluge)
    not_found = []           # queries found on neither Soulseek nor a tracker
    soulseek_downloaded = [] # queries fetched from Soulseek (synchronous)
    entries = extract_entries(csv_path: csv_path, csv_content: csv_content)
    total = entries.size
    speaker = app.respond_to?(:speaker) ? app.speaker : nil
    source = soulseek_primary? ? 'soulseek-first' : 'trackers-first'
    speaker&.speak_up("music import_csv: starting (total #{total}, quality '#{MusicQuality.label(quality)}', source '#{source}')", 0)

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
    record_queued = lambda do |name|
      queued << name
      progress['queued'] += 1
      progress['queued_titles'] = queued.first(IMPORT_REPORT_SAMPLE)
    end
    record_not_found = lambda do |query|
      not_found << query
      progress['not_found'] += 1
      progress['not_found_entries'] = not_found.first(IMPORT_REPORT_SAMPLE)
    end

    if soulseek_primary?
      # Option B: Soulseek is the primary source — hand it the whole batch first,
      # then fall back to the trackers only for what it could not fetch.
      sl = SoulseekSearch.fetch(entries: entries.map { |e| soulseek_entry(e, e['query']) }, quality: quality)
      soulseek_downloaded = sl ? Array(sl['downloaded_entries']) : []
      progress['processed'] = soulseek_downloaded.size
      remaining = entries.reject { |e| soulseek_downloaded.include?(e['query']) }
      speaker&.speak_up("music import_csv: soulseek downloaded #{soulseek_downloaded.size}/#{total}; #{remaining.size} left#{' for the trackers' if tracker_fallback?}", 0)

      remaining.each do |entry|
        query = entry['query']
        progress['processed'] += 1
        progress['current_query'] = query
        # tracker_fallback:false -> Soulseek only: unfound stays unfound.
        unless tracker_fallback?
          record_not_found.call(query)
          update_progress.call
          next
        end
        begin
          name = tracker_queue_entry(entry, quality: quality, limit: limit, fallback_done: fallback_done)
          name ? record_queued.call(name) : record_not_found.call(query)
        rescue StandardError => e
          record_not_found.call(query)
          app.speaker.tell_error(e, "music import_csv query '#{query}'") rescue nil
        end
        update_progress.call
      end
    else
      # Option A (rollback path): trackers first, Soulseek as a fallback for the
      # misses. Kept working so switching back only takes a config change.
      soulseek_candidates = []
      entries.each do |entry|
        query = entry['query']
        progress['processed'] += 1
        progress['current_query'] = query
        begin
          name = tracker_queue_entry(entry, quality: quality, limit: limit, fallback_done: fallback_done)
          if name
            record_queued.call(name)
          else
            record_not_found.call(query)
            soulseek_candidates << soulseek_entry(entry, query)
          end
        rescue StandardError => e
          record_not_found.call(query)
          soulseek_candidates << soulseek_entry(entry, query)
          app.speaker.tell_error(e, "music import_csv query '#{query}'") rescue nil
        end
        update_progress.call
      end
      sl = run_soulseek_fallback(soulseek_candidates, quality)
      soulseek_downloaded = sl ? Array(sl['downloaded_entries']) : []
      not_found -= soulseek_downloaded
    end

    update_progress.call(true)
    speaker&.speak_up("music import_csv: done (soulseek #{soulseek_downloaded.size}, queued #{queued.size}, not found #{not_found.size})", 0)
    import_csv_report(queued, not_found, detailed, soulseek_downloaded: soulseek_downloaded)
  rescue => e
    # Even on an unexpected top-level failure, return what was accumulated so the
    # UI shows a real report instead of a blank "failed" with zeroes.
    app.speaker.tell_error(e, Utils.arguments_dump(binding), 0) rescue nil
    import_csv_report(queued, not_found, detailed, soulseek_downloaded: soulseek_downloaded)
  end

  # Report the three possible outcomes distinctly: tracker-queued (async, waiting
  # on Deluge), soulseek-downloaded (already on disk), and still-not-found.
  def self.import_csv_report(queued, not_found, detailed, soulseek_downloaded: [])
    soulseek_downloaded = Array(soulseek_downloaded)
    return queued.size + soulseek_downloaded.size unless detailed

    report = {
      'total_queued' => queued.size, 'queued_titles' => queued.first(IMPORT_REPORT_SAMPLE),
      'not_found' => not_found.size, 'not_found_entries' => not_found.first(IMPORT_REPORT_SAMPLE)
    }
    unless soulseek_downloaded.empty?
      report['soulseek_downloaded'] = soulseek_downloaded.size
      report['soulseek_downloaded_entries'] = soulseek_downloaded.first(IMPORT_REPORT_SAMPLE)
    end
    report
  end

  # Runs the existing tracker search (with the min-seeders hardening and the
  # once-per-artist discography fallback) for one entry and queues the best
  # match. Returns the queued release name, or nil when nothing was found.
  def self.tracker_queue_entry(entry, quality:, limit:, fallback_done:)
    query = entry['query']
    results = search(keyword: query, quality: quality, limit: limit, filter_dead: min_seeders_import)
    best = results.first
    if best.nil?
      fallback = artist_fallback(entry['artist'], query)
      if fallback && !fallback_done[fallback.downcase]
        fallback_done[fallback.downcase] = true
        results = search(keyword: fallback, quality: quality, limit: limit, filter_dead: min_seeders_import)
        best = results.first
      end
    end
    return nil if best.nil?

    queue_download(
      name: best[:name], link: best[:link], tracker: best[:tracker],
      size: best[:size], seeders: best[:seeders], torrent_link: best[:torrent_link],
      added: best[:added], quality: quality
    )
    best[:name]
  end

  def self.soulseek_conf
    cfg = app.config['music'] && app.config['music']['soulseek']
    cfg.is_a?(Hash) ? cfg : {}
  rescue StandardError
    {}
  end

  def self.soulseek_config_flag(value, default)
    return default if value.nil?

    value != false && value.to_s.strip.downcase != 'false'
  end

  # Option B is active only when the config opts in (music.soulseek.primary) and
  # the sockseek fallback is actually usable.
  def self.soulseek_primary?
    return false unless soulseek_config_flag(soulseek_conf['primary'], false)

    SoulseekSearch.available?
  rescue StandardError
    false
  end

  # Whether Soulseek misses fall back to the BitTorrent trackers (default true);
  # set false for a Soulseek-only import.
  def self.tracker_fallback?
    soulseek_config_flag(soulseek_conf['tracker_fallback'], true)
  end

  # Runs the Soulseek fallback over the collected tracker misses, returning its
  # report or nil when the fallback is unconfigured, unavailable, or errors.
  def self.run_soulseek_fallback(candidates, quality)
    return nil if candidates.nil? || candidates.empty?
    return nil unless SoulseekSearch.available?

    SoulseekSearch.fetch(entries: candidates, quality: quality)
  rescue StandardError => e
    app.speaker.tell_error(e, 'music import_csv soulseek fallback') rescue nil
    nil
  end

  # Builds the { artist:, album:, query: } entry the Soulseek fallback expects
  # from a not-found CSV row. When the artist is known and prefixes the
  # "<artist> <album>" query, only the album part is kept so sockseek searches
  # the album rather than the concatenation; free-text lines pass the whole
  # query as the album search term.
  def self.soulseek_entry(entry, query)
    artist = (entry.is_a?(Hash) ? entry['artist'] : nil).to_s.strip
    album = query.to_s.strip
    if !artist.empty? && album.downcase.start_with?(artist.downcase)
      trimmed = album[artist.length..].to_s.strip
      album = trimmed unless trimmed.empty?
    end
    { artist: (artist.empty? ? nil : artist), album: album, query: query }
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

  # Minimum seeders a release must have to be auto-queued by the CSV import.
  # Configured via music.min_seeders; falls back to DEFAULT_MIN_SEEDERS_IMPORT.
  # Only the automatic import enforces this; the interactive search keeps its
  # lenient default so a rare 1-seeder result stays visible.
  def self.min_seeders_import
    configured = app.config['music'] && app.config['music']['min_seeders']
    configured.to_i.positive? ? configured.to_i : DEFAULT_MIN_SEEDERS_IMPORT
  rescue
    DEFAULT_MIN_SEEDERS_IMPORT
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

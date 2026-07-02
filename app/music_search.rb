# frozen_string_literal: true

require 'csv'

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
    svc.get_trackers(sources).each do |tracker|
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
      :move_completed => music_destination,
      :whitelisted_extensions => FileUtils.get_valid_extensions(CATEGORY),
      :music_quality => quality.to_s
    }
    TorrentSearch.torrent_download(torrent, 1, 1, [], CATEGORY)
    { 'queued' => name }
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    { 'error' => e.message }
  end

  # CSV import: one free-text query per line. For each query, run a music search
  # and auto-queue the best matching result for the requested quality.
  def self.import_csv(csv_path: nil, csv_content: nil, quality: nil, limit: 50, detailed: false)
    queries = extract_queries(csv_path: csv_path, csv_content: csv_content)
    total = queries.size
    speaker = app.respond_to?(:speaker) ? app.speaker : nil
    speaker&.speak_up("music import_csv: starting (total #{total}, quality '#{MusicQuality.label(quality)}')", 0)

    queued = []
    not_found = []
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

    queries.each do |query|
      progress['processed'] += 1
      progress['current_query'] = query
      results = search(keyword: query, quality: quality, limit: limit)
      best = results.first
      if best.nil?
        not_found << query
        progress['not_found'] += 1
        progress['not_found_entries'] = not_found.first(50)
        speaker&.speak_up("music import_csv: #{progress['processed']}/#{total} '#{query}' -> no result", 0)
      else
        queue_download(
          name: best[:name], link: best[:link], tracker: best[:tracker],
          size: best[:size], seeders: best[:seeders], torrent_link: best[:torrent_link],
          added: best[:added], quality: quality
        )
        queued << best[:name]
        progress['queued'] += 1
        progress['queued_titles'] = queued.first(50)
        speaker&.speak_up("music import_csv: #{progress['processed']}/#{total} '#{query}' -> queued '#{best[:name]}'", 0)
      end
      update_progress.call
    end

    update_progress.call(true)
    speaker&.speak_up("music import_csv: done (queued #{queued.size}, not found #{not_found.size})", 0)
    if detailed
      { 'total_queued' => queued.size, 'queued_titles' => queued.first(50),
        'not_found' => not_found.size, 'not_found_entries' => not_found.first(50) }
    else
      queued.size
    end
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding), 0) rescue nil
    detailed ? { 'total_queued' => 0, 'queued_titles' => [], 'not_found' => 0, 'not_found_entries' => [] } : 0
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
    content = if !csv_content.to_s.empty?
                csv_content.to_s
              elsif csv_path.to_s.strip != ''
                raise ArgumentError, "CSV file not found: #{csv_path}" unless File.file?(csv_path)

                File.read(csv_path)
              else
                raise ArgumentError, 'missing_csv'
              end
    lines = content.lines.map(&:strip).reject(&:empty?)
    lines.shift if lines.first && lines.first.downcase.delete('"').strip == 'query'
    lines.map { |line| line.sub(/\A"(.*)"\z/, '\1').strip }.reject(&:empty?)
  end

  def self.tracker_query_service
    MediaLibrarian::Services::TrackerQueryService.new(app: app)
  end
end

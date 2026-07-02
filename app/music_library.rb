# frozen_string_literal: true

require 'find'

# Organizes downloaded music files into an "Artist/Album/NN - Title.ext" tree.
#
# Metadata comes from the embedded audio tags (via MediaInfo); when a tag is
# missing it falls back to parsing the torrent folder and file names. Files
# coming from outside the library are hard-linked in (the original stays
# available for seeding); files already inside the library are moved in place,
# so re-running organize re-files tracks whose metadata has improved (e.g.
# after enabling MusicBrainz/AcoustID lookups).
class MusicLibrary
  include MediaLibrarian::AppContainerSupport

  TAG_KEYS = %i[artist album title track disc year].freeze
  MAX_COMPONENT_LENGTH = 120
  LOSSLESS_EXTENSIONS = %w[flac alac ape wav wv aiff aif tak tta].freeze

  # Organize every audio file found under +source+ (a folder or a single file)
  # into +destination+ (defaults to the configured music library root, which is
  # also the default source: organizing the library itself re-files misplaced
  # tracks in place). Reports progress on the current job when run as one.
  def self.organize(source: nil, destination: nil)
    destination = (destination.to_s.strip.empty? ? MusicSearch.music_destination : destination.to_s)
    source = source.to_s.strip.empty? ? destination : source.to_s
    return { 'organized' => 0, 'skipped' => 0, 'destination' => destination } unless File.exist?(source)

    files = audio_files(source)
    progress = { 'processed' => 0, 'organized' => 0, 'skipped' => 0, 'total' => files.size, 'current_file' => nil }
    jid = Thread.current[:jid]
    update_progress = lambda do |force = false|
      return unless jid && defined?(Daemon) && Daemon.respond_to?(:update_job_progress, true)
      return unless force || (progress['processed'].positive? && (progress['processed'] % 10).zero?)

      Daemon.send(:update_job_progress, jid, progress.dup)
    end
    update_progress.call(true)
    files.each do |file|
      progress['processed'] += 1
      progress['current_file'] = File.basename(file)
      dest = organize_file(file, destination, folder_name: File.basename(File.dirname(file)))
      progress[dest ? 'organized' : 'skipped'] += 1
      update_progress.call
    end
    update_progress.call(true)
    app.speaker.speak_up("music organize: #{progress['organized']} file(s) organized, #{progress['skipped']} already in place (destination #{destination})", 0) if app.respond_to?(:speaker)
    { 'organized' => progress['organized'], 'skipped' => progress['skipped'], 'destination' => destination }
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    { 'organized' => 0, 'skipped' => 0, 'destination' => destination }
  end

  # Organize a single audio file. Returns the destination path when the library
  # changed (file linked, moved or deduplicated), nil when nothing was done.
  def self.organize_file(path, destination_root, folder_name: nil)
    ext = FileUtils.get_extension(path).to_s.downcase
    return nil unless EXTENSIONS_TYPE[:audio].include?(ext)

    destination_root = File.expand_path(destination_root.to_s)
    path = File.expand_path(path.to_s)
    in_place = path.start_with?(destination_root + '/')

    tags = read_tags(path)
    # For files already inside the library, the Artist/Album directory structure
    # is authoritative when tags are missing — without this, a re-organize run
    # with unreadable tags would demote well-placed files to 'Unknown Artist'.
    tags = merge_tags(tags, tags_from_library_path(path, destination_root)) if in_place
    tags = complete_tags(merge_tags(tags, parse_from_names(File.basename(path, ".#{ext}"), folder_name)), path)
    relative = build_relative_path(tags, ext, File.basename(path, ".#{ext}"))
    dest = File.join(destination_root, relative)
    return nil if path == dest # already organized

    # Deduplicate by quality: an existing version of the same track (same
    # "NN - Title" stem, any audio extension) is kept unless the incoming file
    # is of higher quality, in which case it replaces the older version(s).
    siblings = audio_siblings(File.dirname(dest), File.basename(dest, ".#{ext}")) - [path]
    unless siblings.empty?
      incoming_score = quality_score(path)
      best_existing = siblings.max_by { |file| quality_score(file) }
      if incoming_score > quality_score(best_existing)
        siblings.each { |file| safe_remove(file, destination_root) }
        app.speaker.speak_up("music organize: replacing lower-quality version of '#{File.basename(dest)}'") if Env.debug?
      else
        app.speaker.speak_up("music organize: keeping existing higher/equal-quality '#{File.basename(best_existing)}', skipping") if Env.debug?
        if in_place
          # The source is a redundant lower-quality copy inside the library.
          safe_remove(path, destination_root)
          prune_empty_dirs(File.dirname(path), destination_root)
          return best_existing
        end
        return nil
      end
    end

    FileUtils.mkdir_p(File.dirname(dest))
    if in_place
      FileUtils.mv(path, dest)
      prune_empty_dirs(File.dirname(path), destination_root)
    else
      link_or_copy(path, dest)
    end
    app.speaker.speak_up("music organize: '#{File.basename(path)}' -> '#{relative}'") if Env.debug?
    dest
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    nil
  end

  # --- Pure helpers (no I/O, unit-tested) -----------------------------------

  def self.build_relative_path(tags, ext, fallback_base = '')
    artist = present(tags[:artist]) ? tags[:artist] : 'Unknown Artist'
    album = present(tags[:album]) ? tags[:album] : 'Unknown Album'
    title = present(tags[:title]) ? tags[:title] : fallback_base.to_s
    title = 'Unknown Title' unless present(title)

    track = tags[:track].to_s[/\d+/]
    disc = tags[:disc].to_s[/\d+/]
    core = if track
             prefix = format('%02d', track.to_i)
             prefix = "#{disc.to_i}-#{prefix}" if disc && disc.to_i > 0
             "#{prefix} - #{title}"
           else
             title
           end
    filename = "#{sanitize_component(core)}.#{ext}"
    File.join(sanitize_component(artist), sanitize_component(album), filename)
  end

  # Filesystem-safe single path component.
  def self.sanitize_component(str)
    value = str.to_s.strip
    value = value.gsub(%r{[/\\]}, '-')                # path separators
    value = value.gsub(/[:*?"<>|\x00-\x1f]/, '')      # illegal / control chars
    value = value.gsub(/\s+/, ' ').strip
    value = value.gsub(/[ .]+\z/, '')                 # trailing dots/spaces
    value = value[0, MAX_COMPONENT_LENGTH].to_s.strip
    value.empty? ? 'Unknown' : value
  end

  # Best-effort tags from the torrent folder name and the file name, used when
  # embedded tags are missing.
  def self.parse_from_names(basename, folder_name)
    tags = { :artist => '', :album => '', :title => '', :track => '', :disc => '', :year => '' }

    folder = folder_name.to_s.gsub(/\[[^\]]*\]/, ' ').gsub(/\{[^}]*\}/, ' ')
    year = folder[/\((\d{4})\)/, 1] || folder[/\b(19|20)\d{2}\b/]
    tags[:year] = year.to_s
    folder = folder.gsub(/\((\d{4})\)/, ' ').gsub(/\b(19|20)\d{2}\b/, ' ').gsub(/\s+/, ' ').strip
    if folder.include?(' - ')
      artist, album = folder.split(/\s+-\s+/, 2)
      tags[:artist] = artist.to_s.strip
      tags[:album] = album.to_s.strip
    elsif !folder.empty?
      tags[:album] = folder
    end

    base = basename.to_s.gsub(/\[[^\]]*\]/, ' ').gsub(/\s+/, ' ').strip
    if (match = base.match(/\A(?:(\d+)[-.])?\s*(\d{1,3})[\s._-]+(.+)\z/))
      tags[:disc] = match[1].to_s
      tags[:track] = match[2].to_s
      title = match[3].to_s.strip
      if tags[:artist].empty? && title.include?(' - ')
        maybe_artist, maybe_title = title.split(/\s+-\s+/, 2)
        tags[:artist] = maybe_artist.strip
        title = maybe_title.strip
      end
      tags[:title] = title
    elsif base.include?(' - ')
      maybe_artist, maybe_title = base.split(/\s+-\s+/, 2)
      tags[:artist] = maybe_artist.strip if tags[:artist].empty?
      tags[:title] = maybe_title.strip
    else
      tags[:title] = base
    end
    tags
  end

  def self.merge_tags(primary, fallback)
    TAG_KEYS.each_with_object({}) do |key, memo|
      memo[key] = present(primary[key]) ? primary[key].to_s.strip : fallback[key].to_s.strip
    end
  end

  # Artist/album inferred from a file's position inside the library
  # ("Artist/Album/file.ext" relative to the root). 'Unknown *' placeholders are
  # ignored so those files remain improvable by metadata lookups.
  def self.tags_from_library_path(path, destination_root)
    parts = path.to_s.sub(File.expand_path(destination_root.to_s) + '/', '').split('/')
    return {} if parts.length < 3

    tags = {}
    tags[:artist] = parts[0] unless parts[0] == 'Unknown Artist'
    tags[:album] = parts[1] unless parts[1] == 'Unknown Album'
    tags
  end

  def self.present(value)
    !value.to_s.strip.empty?
  end

  # Comparable quality score derived from the file name / extension. Used as a
  # fallback when MediaInfo cannot read the stream. Lossless extensions always
  # outrank lossy; markers (24bit/hi-res, bitrate, V0/V2) refine within a class.
  def self.name_quality_score(path)
    name = File.basename(path.to_s).downcase
    ext = FileUtils.get_extension(name).to_s.downcase
    if LOSSLESS_EXTENSIONS.include?(ext) || name.match?(/\b(flac|alac|lossless|ape)\b/)
      score = 1_000_000
      score += 500_000 if name.match?(/24[\s._-]?bit|\b24b\b|hi[\s._-]?res|hires|\b(?:96|176|192)[\s._-]?k?hz\b/)
      score
    elsif (match = name.match(/\b(\d{2,4})\s?kbps\b/) || name.match(/\b(320|256|224|192|160|128)\b/))
      match[1].to_i * 1000
    elsif name.match?(/\bv0\b/)
      245_000
    elsif name.match?(/\bv2\b/)
      190_000
    else
      100_000
    end
  end

  # --- I/O helpers ----------------------------------------------------------

  def self.quality_score(path)
    score = begin
      Env.pretend? ? nil : FileInfo.new(path).audio_quality_score
    rescue
      nil
    end
    score || name_quality_score(path)
  end

  # Existing audio files in +dir+ that represent the same track as +stem+
  # (same base name, ignoring the audio extension).
  def self.audio_siblings(dir, stem)
    return [] unless File.directory?(dir)

    Dir.children(dir).filter_map do |entry|
      full = File.join(dir, entry)
      next unless File.file?(full)

      ext = FileUtils.get_extension(entry).to_s.downcase
      next unless EXTENSIONS_TYPE[:audio].include?(ext)
      next unless File.basename(entry, ".#{ext}") == stem

      full
    end
  end

  # Remove a file only when it lives inside the library root, to avoid deleting
  # anything outside the organized destination.
  def self.safe_remove(path, destination_root)
    return unless File.expand_path(path).start_with?(File.expand_path(destination_root) + '/')

    File.delete(path) if File.exist?(path)
  rescue
    nil
  end

  # Find.find rather than Dir.glob: torrent folder names routinely contain glob
  # metacharacters ('[FLAC]', '{...}') that would silently match nothing.
  def self.audio_files(source)
    return [source] unless File.directory?(source)

    files = []
    Find.find(source) do |file|
      files << file if File.file?(file) && EXTENSIONS_TYPE[:audio].include?(FileUtils.get_extension(file).to_s.downcase)
    end
    files.sort
  end

  # Remove now-empty directories left behind by an in-place move, up to (but
  # never including) the library root.
  def self.prune_empty_dirs(dir, destination_root)
    root = File.expand_path(destination_root)
    dir = File.expand_path(dir)
    while dir.start_with?(root + '/') && File.directory?(dir) && Dir.empty?(dir)
      Dir.rmdir(dir)
      dir = File.dirname(dir)
    end
  rescue
    nil
  end

  def self.read_tags(path)
    return {} if Env.pretend?

    FileInfo.new(path).audio_tags
  rescue
    {}
  end

  # Fill missing artist/album/title from external metadata providers when tags
  # and name parsing left gaps. AcoustID (acoustic fingerprint) is tried first
  # because it identifies a track even without any usable tags/name; MusicBrainz
  # text search then fills any remaining gap. Existing tags always take
  # precedence over looked-up values.
  def self.complete_tags(tags, path = nil)
    return tags if present(tags[:artist]) && present(tags[:album]) && present(tags[:title])

    if path && acoustid_enabled? && !(present(tags[:artist]) && present(tags[:title]))
      client = acoustid
      found = client&.lookup(path)
      tags = merge_tags(tags, symbolize_tags(found)) if found && !found.empty?
      return tags if present(tags[:artist]) && present(tags[:album]) && present(tags[:title])
    end

    if musicbrainz_enabled?
      client = musicbrainz
      if client
        found = client.complete(artist: tags[:artist], album: tags[:album], title: tags[:title], track: tags[:track])
        tags = merge_tags(tags, symbolize_tags(found)) if found && !found.empty?
      end
    end
    tags
  rescue
    tags
  end

  def self.symbolize_tags(hash)
    TAG_KEYS.each_with_object({}) { |key, memo| memo[key] = (hash[key] || hash[key.to_s]).to_s }
  end

  def self.config_flag(key, default_when_missing)
    value = app.config['music'] && app.config['music'][key]
    return default_when_missing if value.nil?

    value == true || value.to_s.strip.downcase == 'true' || value.to_i > 0
  rescue
    false
  end

  def self.musicbrainz_enabled?
    config_flag('musicbrainz', true)
  end

  def self.acoustid_key
    (app.config['music'] && app.config['music']['acoustid_key']).to_s.strip
  rescue
    ''
  end

  def self.acoustid_enabled?
    !acoustid_key.empty? && config_flag('acoustid', true)
  end

  # Metadata clients are memoized against the current 'music' config so a
  # `daemon reload` with a changed key/contact/TTL rebuilds them.
  def self.metadata_clients
    cfg = (app.config['music'] rescue nil)
    return @metadata_clients[1] if @metadata_clients && @metadata_clients[0] == cfg

    speaker = app.respond_to?(:speaker) ? app.speaker : nil
    ttl = (cfg && cfg['cache_ttl_days']).to_i
    cache = JsonDiskCache.new(
      dir: File.join(app.config_dir, 'cache', 'metadata'),
      ttl_days: ttl.positive? ? ttl : JsonDiskCache::DEFAULT_TTL_DAYS,
      speaker: speaker
    )
    @metadata_clients = [(cfg.respond_to?(:deep_dup) ? cfg.deep_dup : cfg), {
      :musicbrainz => MusicBrainzApi.new(contact: (cfg && cfg['musicbrainz_contact']).to_s, speaker: speaker, cache: cache),
      :acoustid => AcoustidApi.new(api_key: acoustid_key, speaker: speaker, cache: cache)
    }]
    @metadata_clients[1]
  rescue
    nil
  end

  def self.musicbrainz
    metadata_clients&.dig(:musicbrainz)
  end

  def self.acoustid
    metadata_clients&.dig(:acoustid)
  end

  def self.link_or_copy(source, dest)
    File.link(source, dest)
  rescue SystemCallError
    IO.copy_stream(source, dest)
  end
end

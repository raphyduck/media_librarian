# frozen_string_literal: true

# Organizes downloaded music files into an "Artist/Album/NN - Title.ext" tree.
#
# Metadata comes from the embedded audio tags (via MediaInfo); when a tag is
# missing it falls back to parsing the torrent folder and file names. Files are
# hard-linked into the destination so the original stays available for seeding.
class MusicLibrary
  include MediaLibrarian::AppContainerSupport

  TAG_KEYS = %i[artist album title track disc year].freeze
  MAX_COMPONENT_LENGTH = 120
  LOSSLESS_EXTENSIONS = %w[flac alac ape wav wv aiff aif tak tta].freeze

  # Organize every audio file found under +source+ (a folder or a single file)
  # into +destination+ (defaults to the configured music library root).
  def self.organize(source:, destination: nil, no_prompt: 1)
    destination = (destination.to_s.strip.empty? ? MusicSearch.music_destination : destination.to_s)
    source = source.to_s
    return { 'organized' => 0, 'destination' => destination } if source.empty? || !File.exist?(source)

    organized = 0
    audio_files(source).each do |file|
      dest = organize_file(file, destination, folder_name: File.basename(File.dirname(file)), no_prompt: no_prompt)
      organized += 1 if dest
    end
    app.speaker.speak_up("music organize: #{organized} file(s) organized into #{destination}", 0) if app.respond_to?(:speaker)
    { 'organized' => organized, 'destination' => destination }
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    { 'organized' => 0, 'destination' => destination }
  end

  # Organize a single audio file. Returns the destination path (or nil).
  def self.organize_file(path, destination_root, folder_name: nil, no_prompt: 1)
    ext = FileUtils.get_extension(path).to_s.downcase
    return nil unless EXTENSIONS_TYPE[:audio].include?(ext)

    destination_root = File.expand_path(destination_root.to_s)
    # Idempotency: skip files that already live inside the library root.
    return nil if File.expand_path(path).start_with?(destination_root + '/')

    tags = complete_tags(merge_tags(read_tags(path), parse_from_names(File.basename(path, ".#{ext}"), folder_name)))
    relative = build_relative_path(tags, ext, File.basename(path, ".#{ext}"))
    dest = File.join(destination_root, relative)

    # Deduplicate by quality: an existing version of the same track (same
    # "NN - Title" stem, any audio extension) is kept unless the incoming file
    # is of higher quality, in which case it replaces the older version(s).
    siblings = audio_siblings(File.dirname(dest), File.basename(dest, ".#{ext}"))
    unless siblings.empty?
      incoming_score = quality_score(path)
      best_existing = siblings.max_by { |file| quality_score(file) }
      if incoming_score > quality_score(best_existing)
        siblings.each { |file| safe_remove(file, destination_root) }
        app.speaker.speak_up("music organize: replacing lower-quality version of '#{File.basename(dest)}'") if Env.debug?
      else
        app.speaker.speak_up("music organize: keeping existing higher/equal-quality '#{File.basename(best_existing)}', skipping") if Env.debug?
        return best_existing
      end
    end

    FileUtils.mkdir_p(File.dirname(dest))
    link_or_copy(path, dest)
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

  def self.audio_files(source)
    if File.directory?(source)
      Dir.glob(File.join(source, '**', '*')).select do |file|
        File.file?(file) && EXTENSIONS_TYPE[:audio].include?(FileUtils.get_extension(file).to_s.downcase)
      end
    else
      [source]
    end
  end

  def self.read_tags(path)
    return {} if Env.pretend?

    FileInfo.new(path).audio_tags
  rescue
    {}
  end

  # Fill missing artist/album/title from MusicBrainz when enabled. Existing tags
  # always take precedence over the looked-up values.
  def self.complete_tags(tags)
    return tags if present(tags[:artist]) && present(tags[:album]) && present(tags[:title])
    return tags unless musicbrainz_enabled?

    client = musicbrainz
    return tags unless client

    found = client.complete(artist: tags[:artist], album: tags[:album], title: tags[:title], track: tags[:track])
    found.nil? || found.empty? ? tags : merge_tags(tags, symbolize_tags(found))
  rescue
    tags
  end

  def self.symbolize_tags(hash)
    TAG_KEYS.each_with_object({}) { |key, memo| memo[key] = (hash[key] || hash[key.to_s]).to_s }
  end

  def self.musicbrainz_enabled?
    value = app.config['music'] && app.config['music']['musicbrainz']
    value.nil? || value == true || value.to_s.strip.downcase == 'true' || value.to_i > 0
  rescue
    false
  end

  def self.musicbrainz
    @musicbrainz ||= MusicBrainzApi.new(
      contact: (app.config['music'] && app.config['music']['musicbrainz_contact']).to_s,
      speaker: (app.respond_to?(:speaker) ? app.speaker : nil)
    )
  rescue
    nil
  end

  def self.link_or_copy(source, dest)
    File.link(source, dest)
  rescue SystemCallError
    IO.copy_stream(source, dest)
  end
end

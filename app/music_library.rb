# frozen_string_literal: true

require 'find'
require 'digest'

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
  # +apply+ (default false) gates the *destructive* part only: by default organize
  # runs in DRY-RUN mode and just logs which duplicates it *would* trash — files
  # are still filed into place (that is non-destructive). Pass apply:true
  # (CLI: --apply=1) to actually move exact duplicates to the trash folder.
  def self.organize(source: nil, destination: nil, apply: false)
    destination = (destination.to_s.strip.empty? ? MusicSearch.music_destination : destination.to_s)
    source = source.to_s.strip.empty? ? destination : source.to_s
    return { 'organized' => 0, 'skipped' => 0, 'destination' => destination } unless File.exist?(source)

    dry_run = !flag_true?(apply)
    files = audio_files(source)
    # A folder whose tracks share one album but carry several artists is a
    # compilation: file it under a single "Various Artists" folder and stamp
    # ALBUMARTIST/COMPILATION so Navidrome shows one album, not one per artist.
    compilation_dirs = compilation_dirs(files)
    app.speaker.speak_up("music organize: #{files.size} file(s) under '#{source}'#{", #{compilation_dirs.size} compilation folder(s)" unless compilation_dirs.empty?}#{' [DRY-RUN: no deletions, pass --apply=1 to act]' if dry_run}", 0) if app.respond_to?(:speaker)
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
      dest = organize_file(file, destination, folder_name: File.basename(File.dirname(file)),
                                              dry_run: dry_run, compilation: compilation_dirs.include?(File.dirname(file)))
      progress[dest ? 'organized' : 'skipped'] += 1
      update_progress.call
    end
    update_progress.call(true)
    app.speaker.speak_up("music organize: #{progress['organized']} file(s) organized, #{progress['skipped']} already in place (destination #{destination})#{' [DRY-RUN]' if dry_run}", 0) if app.respond_to?(:speaker)
    { 'organized' => progress['organized'], 'skipped' => progress['skipped'], 'destination' => destination, 'dry_run' => dry_run }
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    { 'organized' => 0, 'skipped' => 0, 'destination' => destination }
  end

  # Organize a single audio file. Returns the destination path when the library
  # changed (file linked, moved or deduplicated), nil when nothing was done.
  def self.organize_file(path, destination_root, folder_name: nil, dry_run: true, compilation: false)
    ext = FileUtils.get_extension(path).to_s.downcase
    return nil unless EXTENSIONS_TYPE[:audio].include?(ext)

    destination_root = fs_utf8(File.expand_path(destination_root.to_s))
    path = fs_utf8(File.expand_path(fs_utf8(path)))
    in_place = path.start_with?(destination_root + '/')

    tags = read_tags(path)
    # For files already inside the library, the Artist/Album directory structure
    # is authoritative when tags are missing — without this, a re-organize run
    # with unreadable tags would demote well-placed files to 'Unknown Artist'.
    tags = merge_tags(tags, tags_from_library_path(path, destination_root)) if in_place
    tags = complete_tags(merge_tags(tags, parse_from_names(File.basename(path, ".#{ext}"), folder_name)), path)
    # A compilation track keeps its own :artist tag but is filed under a single
    # "Various Artists" folder (the album-artist), not one folder per track artist.
    folder_artist = compilation ? compilation_artist : nil
    relative = build_relative_path(tags, ext, File.basename(path, ".#{ext}"), folder_artist: folder_artist)
    dest = fs_utf8(File.join(destination_root, relative))
    return nil if path == dest # already organized

    # DEDUP SAFETY: only ever remove a file that is byte-for-byte identical to the
    # incoming one (a true duplicate). We never delete based on tag/title matches
    # — that logic once wiped unrelated albums. And if the sibling scan itself
    # failed (e.g. an encoding error), we abandon dedup entirely and never delete.
    siblings = same_track_siblings(File.dirname(dest), tags)
    return nil if siblings.nil? && in_place # scan failed on an in-place file: do nothing, never delete
    siblings = Array(siblings) - [path]
    exact_dups = siblings.select { |file| same_content?(path, file) }

    unless exact_dups.empty?
      if in_place
        # This copy inside the library is identical to another already-filed one.
        removed = remove_or_log(path, destination_root, dry_run: dry_run, reason: "identical to #{File.basename(exact_dups.first)}")
        prune_empty_dirs(File.dirname(path), destination_root) if removed && removed != :dry_run
        return exact_dups.first
      end
      # Incoming (from outside) is already present identically — nothing to add.
      app.speaker.speak_up("music organize: '#{File.basename(path)}' already present identically, skipping") if Env.debug?
      return nil
    end

    # Never clobber a different file that already sits at the destination path.
    if File.exist?(dest) && !same_content?(path, dest)
      app.speaker.speak_up("music organize: '#{relative}' already exists with different content, leaving both") if Env.debug?
      return nil
    end

    FileUtils.mkdir_p(File.dirname(dest))
    if in_place
      FileUtils.mv(path, dest)
      prune_empty_dirs(File.dirname(path), destination_root)
    else
      link_or_copy(path, dest)
    end
    # Stamp ALBUMARTIST + COMPILATION so Navidrome groups the release as one
    # album. Gated by apply (dry-run only logs) since it rewrites the file.
    TagWriter.stamp_compilation(dest, album_artist: compilation_artist, dry_run: dry_run,
                                      speaker: (app.speaker if app.respond_to?(:speaker))) if compilation
    app.speaker.speak_up("music organize: '#{File.basename(path)}' -> '#{relative}'") if Env.debug?
    dest
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    nil
  end

  # --- Pure helpers (no I/O, unit-tested) -----------------------------------

  # folder_artist overrides the artist directory (used to file a compilation
  # under "Various Artists" while each track keeps its own :artist tag).
  def self.build_relative_path(tags, ext, fallback_base = '', folder_artist: nil)
    artist = if present(folder_artist)
               folder_artist
             else
               present(tags[:artist]) ? tags[:artist] : 'Unknown Artist'
             end
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

  # Existing audio files in +dir+ that are the SAME track as the incoming file,
  # matched on tags — artist, album, album year and title — rather than on the
  # file name, so a higher-quality re-download replaces an existing copy even
  # when the two follow different naming conventions.
  # Returns the matching sibling paths, or nil when the scan could not be
  # completed (e.g. an encoding error) so the caller can fail closed and never
  # delete on uncertainty. Filesystem entries are retagged to UTF-8 because a
  # daemon started without a UTF-8 locale hands them back as ASCII-8BIT, and
  # joining those with a UTF-8 path raised "incompatible character encodings".
  def self.same_track_siblings(dir, tags)
    dir = fs_utf8(dir)
    return [] unless File.directory?(dir)

    Dir.children(dir).filter_map do |entry|
      entry = fs_utf8(entry)
      full = File.join(dir, entry)
      next unless File.file?(full)

      ext = FileUtils.get_extension(entry).to_s.downcase
      next unless EXTENSIONS_TYPE[:audio].include?(ext)
      next unless same_track?(tags, read_tags(full))

      full
    rescue StandardError
      next # a single bad entry must not abort the scan
    end
  rescue StandardError => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    nil
  end

  # Two tag sets describe the same track when their artist, album and title
  # match (case/spacing/punctuation-insensitive) and their album years are
  # compatible. A title is required on both sides so untagged files are never
  # collapsed together.
  def self.same_track?(a, b)
    return false unless present(a[:title]) && present(b[:title])

    %i[artist album title].all? { |key| norm_tag(a[key]) == norm_tag(b[key]) } &&
      years_compatible?(a[:year], b[:year])
  end

  # Album years are compatible when equal, or when at least one side is unknown.
  # A known, differing year marks distinct releases (e.g. an original pressing
  # versus a later remaster) and must not be deduplicated together.
  def self.years_compatible?(year_a, year_b)
    a = year_a.to_s[/\d{4}/]
    b = year_b.to_s[/\d{4}/]
    a.nil? || b.nil? || a == b
  end

  # Normalise a tag value for comparison: case-folded, punctuation flattened to
  # spaces, surrounding/collapsed whitespace removed.
  def self.norm_tag(value)
    value.to_s.downcase.gsub(/[^[:alnum:]]+/, ' ').strip.gsub(/\s+/, ' ')
  end

  # Album title stripped of edition/version qualifiers, so different editions of
  # the same album compare equal ("Discovery (Deluxe Edition)" -> "Discovery").
  EDITION_WORDS = "deluxe|expanded|remaster(?:ed)?|anniversary|collector'?s?|special|bonus|legacy|edition|version"
  def self.norm_album_base(album)
    s = album.to_s.strip
    s = s.gsub(/\s*[\(\[][^)\]]*\b(?:#{EDITION_WORDS})\b[^)\]]*[\)\]]/i, '')
    s = s.sub(/\s*[:\-]\s*[^:]*\b(?:#{EDITION_WORDS})\b.*\z/i, '')
    s.gsub(/\s+/, ' ').strip
  end

  # Album-artist used for compilations, configurable via music.compilation_artist.
  def self.compilation_artist
    configured = (app.config['music'] && app.config['music']['compilation_artist']).to_s.strip
    configured.empty? ? TagWriter::COMPILATION_ARTIST : configured
  rescue StandardError
    TagWriter::COMPILATION_ARTIST
  end

  # Source directories that hold a various-artists compilation: their audio
  # tracks share ONE (base) album title but carry two or more distinct artists.
  # Grouping by directory (co-located tracks) avoids false positives such as
  # several unrelated artists each having a "Greatest Hits" album.
  def self.compilation_dirs(files)
    Array(files).group_by { |f| File.dirname(f) }.each_with_object([]) do |(dir, dfiles), comps|
      tagset = dfiles.map { |f| read_tags(f) }
      albums = tagset.map { |t| norm_album_base(t[:album]) }.reject(&:empty?).uniq
      artists = tagset.map { |t| norm_tag(t[:artist]) }.reject(&:empty?).uniq
      comps << dir if albums.size == 1 && artists.size >= 2
    end
  rescue StandardError
    []
  end

  # Retag a filesystem string as UTF-8 (its bytes already are), scrubbing any
  # genuinely invalid byte. Frozen/short-circuits handled.
  def self.fs_utf8(str)
    s = str.to_s
    s = s.dup.force_encoding('UTF-8')
    s.valid_encoding? ? s : s.scrub
  end

  # True only when two files are byte-for-byte identical (same size + SHA-256).
  # This is the ONLY basis on which organize deletes anything.
  def self.same_content?(a, b)
    return false unless a && b && File.file?(a) && File.file?(b)
    return false unless File.size(a) == File.size(b)

    Digest::SHA256.file(a).digest == Digest::SHA256.file(b).digest
  rescue StandardError
    false
  end

  # Root of the reversible trash used instead of a permanent delete. Configurable
  # via music.organize_trash; defaults to a sibling of the library so it is not
  # itself re-scanned by organize.
  def self.trash_root(destination_root)
    configured = (app.config['music'] && app.config['music']['organize_trash']).to_s.strip rescue ''
    return File.expand_path(configured) unless configured.empty?

    File.join(File.dirname(File.expand_path(destination_root.to_s)), '.trash-organize')
  end

  # Reversible removal: move the file into a dated trash folder (never a hard
  # delete), returning the trashed path. Only files inside the library are
  # touched. A failed move leaves the original in place.
  def self.move_to_trash(path, destination_root)
    return nil unless inside_library?(path, destination_root)
    return nil unless File.exist?(path)

    root = File.expand_path(destination_root.to_s)
    rel = File.expand_path(path).sub(root + '/', '')
    rel = File.basename(path) if rel == File.expand_path(path)
    dest = unique_path(File.join(trash_root(destination_root), Time.now.strftime('%Y%m%d'), rel))
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.mv(path, dest)
    dest
  rescue StandardError => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    nil
  end

  # Perform (or, in dry-run, just log) the reversible removal of a library file.
  # Returns :dry_run when only logged, the trashed path when moved, nil otherwise.
  def self.remove_or_log(path, destination_root, dry_run:, reason: '')
    return nil unless inside_library?(path, destination_root)

    if dry_run
      app.speaker.speak_up("music organize [DRY-RUN]: would trash '#{path}'#{" (#{reason})" unless reason.to_s.empty?}", 0) if app.respond_to?(:speaker)
      return :dry_run
    end
    trashed = move_to_trash(path, destination_root)
    app.speaker.speak_up("music organize: trashed '#{path}' -> '#{trashed}'#{" (#{reason})" unless reason.to_s.empty?}", 0) if trashed && app.respond_to?(:speaker)
    trashed
  end

  def self.inside_library?(path, destination_root)
    File.expand_path(path.to_s).start_with?(File.expand_path(destination_root.to_s) + '/')
  rescue StandardError
    false
  end

  # A non-colliding path: append " (2)", " (3)"… before the extension if needed.
  def self.unique_path(path)
    return path unless File.exist?(path)

    dir = File.dirname(path)
    ext = File.extname(path)
    base = File.basename(path, ext)
    (2..1000).each do |i|
      candidate = File.join(dir, "#{base} (#{i})#{ext}")
      return candidate unless File.exist?(candidate)
    end
    path
  end

  def self.flag_true?(value)
    return false if value.nil?
    return value if [true, false].include?(value)

    normalized = value.to_s.strip.downcase
    !normalized.empty? && !%w[0 false no off].include?(normalized)
  end

  def self.lossless?(path)
    LOSSLESS_EXTENSIONS.include?(FileUtils.get_extension(path).to_s.downcase)
  end

  # Section 6 (quality upgrade): once a lossless copy of the SAME track is present
  # in the library, reversibly move the superseded lossy file to the trash.
  # Removes nothing unless a confirmed lossless replacement of the same track
  # exists (never before the better copy is on disk), fails closed if the sibling
  # scan errors, and dry-run only logs. Returns the trashed path / :dry_run, or
  # nil when nothing was done.
  def self.supersede_if_better(old_path, dry_run: true)
    old_path = fs_utf8(File.expand_path(old_path.to_s))
    return nil unless File.file?(old_path)
    return nil if lossless?(old_path) # already lossless — never touch

    root = fs_utf8(File.expand_path(MusicSearch.music_destination))
    return nil unless inside_library?(old_path, root)

    tags = read_tags(old_path)
    siblings = same_track_siblings(File.dirname(old_path), tags)
    return nil if siblings.nil? # scan failed -> fail closed, never delete
    replacement = (siblings - [old_path]).find { |f| lossless?(f) }
    return nil unless replacement

    remove_or_log(old_path, root, dry_run: dry_run, reason: "superseded by lossless #{File.basename(replacement)}")
  rescue StandardError => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    nil
  end

  # One-shot remediation: consolidate various-artists compilations that an older
  # organize run scattered as many single-track "albums" (one folder per track
  # artist, all sharing one album). Unlike organize's per-folder detection, this
  # groups library-wide: tracks sharing one base album but spread across several
  # artist folders are re-filed under a single "Various Artists/<Album>/" folder
  # and stamped ALBUMARTIST/COMPILATION (the move/tagging reuses organize_file,
  # so all its dedup/never-clobber safety applies). Dry-run by default: it only
  # reports the plan and changes nothing unless --apply=1 is passed.
  def self.consolidate_compilations(destination: nil, min_artists: nil, apply: false)
    root = fs_utf8(File.expand_path((destination.to_s.strip.empty? ? MusicSearch.music_destination : destination.to_s)))
    dry_run = !flag_true?(apply)
    return { 'compilations' => 0, 'files' => 0, 'destination' => root, 'dry_run' => dry_run } unless File.directory?(root)

    threshold = compilation_min_artists(min_artists)
    groups = scattered_compilation_groups(audio_files(root), threshold)
    total = groups.sum { |g| g['files'].size }
    app.speaker.speak_up("music consolidate_compilations: #{groups.size} scattered compilation(s), #{total} track(s), min #{threshold} artists#{' [DRY-RUN: no changes, pass --apply=1 to act]' if dry_run}", 0) if app.respond_to?(:speaker)

    va = compilation_artist
    relocated = 0
    groups.each do |group|
      if dry_run
        app.speaker.speak_up("music consolidate_compilations [DRY-RUN]: '#{group['album']}' — #{group['files'].size} track(s) from #{group['dirs']} folder(s), #{group['artists']} artist(s) -> '#{File.join(va, group['album'])}'", 0) if app.respond_to?(:speaker)
        relocated += group['files'].size
      else
        group['files'].each do |file|
          dest = organize_file(file, root, folder_name: File.basename(File.dirname(file)), dry_run: false, compilation: true)
          relocated += 1 if dest
        end
      end
    end
    app.speaker.speak_up("music consolidate_compilations: #{groups.size} compilation(s), #{relocated} track(s) #{dry_run ? 'to relocate' : 'relocated'} (destination #{root})#{' [DRY-RUN]' if dry_run}", 0) if app.respond_to?(:speaker)
    { 'compilations' => groups.size, 'files' => relocated, 'destination' => root, 'dry_run' => dry_run }
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    { 'compilations' => 0, 'files' => 0, 'destination' => root, 'dry_run' => !flag_true?(apply) }
  end

  # Library-wide scattered compilations: audio files sharing one base album but
  # carrying >= min_artists distinct artists across >= 2 directories. The
  # multi-directory requirement excludes already-consolidated compilations (all
  # tracks in one folder); the distinct-artist threshold and a generic-title
  # blocklist guard against unrelated albums that merely share a common title
  # ("Greatest Hits", "Live"...). Returns [{ 'album', 'files', 'artists', 'dirs' }].
  def self.scattered_compilation_groups(files, min_artists)
    index = Hash.new { |h, k| h[k] = [] }
    Array(files).each do |file|
      tags = read_tags(file)
      base = norm_album_base(tags[:album])
      next if base.strip.empty?

      key = norm_tag(base)
      next if key.empty? || generic_compilation_title?(key)

      index[key] << { file: file, album: base, artist: norm_tag(tags[:artist]), dir: File.dirname(file) }
    end

    index.filter_map do |_key, entries|
      artists = entries.map { |e| e[:artist] }.reject(&:empty?).uniq
      dirs = entries.map { |e| e[:dir] }.uniq
      next unless artists.size >= min_artists && dirs.size >= 2

      { 'album' => most_common(entries.map { |e| e[:album] }), 'files' => entries.map { |e| e[:file] }.sort,
        'artists' => artists.size, 'dirs' => dirs.size }
    end
  rescue StandardError => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    []
  end

  def self.most_common(values)
    values.group_by(&:itself).max_by { |_v, occurrences| occurrences.size }&.first.to_s
  end

  DEFAULT_COMPILATION_MIN_ARTISTS = 3
  # Minimum distinct artists for a shared-album group to count as a compilation.
  # CLI override wins, then music.compilation_min_artists, else the default. A
  # floor of 2 is enforced so the guard can never be disabled into merging pairs.
  def self.compilation_min_artists(override = nil)
    candidate = override.to_s.strip.empty? ? nil : override.to_i
    candidate ||= (app.config['music'] && app.config['music']['compilation_min_artists']).to_i rescue nil
    candidate && candidate >= 2 ? candidate : DEFAULT_COMPILATION_MIN_ARTISTS
  rescue StandardError
    DEFAULT_COMPILATION_MIN_ARTISTS
  end

  # Album titles too generic to treat as a compilation when shared by several
  # artists (each artist legitimately having their own). Extendable via
  # music.compilation_blocklist. Compared against norm_tag-normalised titles.
  GENERIC_COMPILATION_TITLES = [
    'greatest hits', 'best of', 'the best of', 'hits', 'live', 'unplugged',
    'demos', 'rarities', 'b sides', 'singles', 'anthology', 'collection'
  ].freeze
  def self.generic_compilation_title?(normalized_album)
    compilation_blocklist.include?(normalized_album)
  end

  def self.compilation_blocklist
    configured = (app.config['music'] && app.config['music']['compilation_blocklist']) rescue nil
    extra = Array(configured).map { |v| norm_tag(v) }.reject(&:empty?)
    (GENERIC_COMPILATION_TITLES + extra).uniq
  rescue StandardError
    GENERIC_COMPILATION_TITLES
  end

  # Find.find rather than Dir.glob: torrent folder names routinely contain glob
  # metacharacters ('[FLAC]', '{...}') that would silently match nothing.
  def self.audio_files(source)
    return [source] unless File.directory?(source)

    files = []
    Find.find(source) do |file|
      file = fs_utf8(file)
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

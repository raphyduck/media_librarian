# frozen_string_literal: true

require 'find'
require_relative '../lib/json_disk_cache'
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

  TAG_KEYS = %i[artist albumartist album title track disc year].freeze
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
  def self.organize(source: nil, destination: nil, apply: false, musicbrainz: nil, write_tags: false)
    destination = (destination.to_s.strip.empty? ? MusicSearch.music_destination : destination.to_s)
    source = source.to_s.strip.empty? ? destination : source.to_s
    return { 'organized' => 0, 'skipped' => 0, 'destination' => destination } unless File.exist?(source)

    dry_run = !flag_true?(apply)
    write_tags = flag_true?(write_tags)
    @album_artist_memo = {} # per-run: one ALBUMARTIST lookup per album folder
    mb_mode = resolve_musicbrainz_mode(musicbrainz)
    files = audio_files(source)
    # A folder whose tracks share one album but carry several artists is a
    # compilation: file it under a single "Various Artists" folder and stamp
    # ALBUMARTIST/COMPILATION so Navidrome shows one album, not one per artist.
    compilation_dirs = compilation_dirs(files)
    app.speaker.speak_up("music organize: #{files.size} file(s) under '#{source}'#{", #{compilation_dirs.size} compilation folder(s)" unless compilation_dirs.empty?} (musicbrainz=#{mb_mode})#{' [DRY-RUN: no deletions, pass --apply=1 to act]' if dry_run}", 0) if app.respond_to?(:speaker)
    progress = { 'processed' => 0, 'organized' => 0, 'skipped' => 0, 'total' => files.size, 'current_file' => nil }
    jid = Thread.current[:jid]
    update_progress = lambda do |force = false|
      return unless jid && defined?(Daemon) && Daemon.respond_to?(:update_job_progress, true)
      return unless force || (progress['processed'].positive? && (progress['processed'] % 10).zero?)

      Daemon.send(:update_job_progress, jid, progress.dup)
    end
    update_progress.call(true)
    # A dry-run reuses the existing Env.pretend? mode: every filesystem write
    # (mv, mkdir, cp, ln, rmdir) is already gated on it, so setting it for the
    # duration makes the run strictly read-only with no parallel dry_run plumbing.
    # Reads (tag scan, quality score) are intentionally NOT gated on pretend, so
    # the plan is still computed. dry_run stays threaded through only to drive the
    # "would trash / would ..." wording in the log.
    prev_pretend = Thread.current[:pretend]
    Thread.current[:pretend] = 1 if dry_run
    begin
      files.each do |file|
        progress['processed'] += 1
        progress['current_file'] = File.basename(file)
        dest = organize_file(file, destination, folder_name: File.basename(File.dirname(file)),
                                                dry_run: dry_run, compilation: compilation_dirs.include?(File.dirname(file)),
                                                musicbrainz_mode: mb_mode, write_tags: write_tags)
        progress[dest ? 'organized' : 'skipped'] += 1
        update_progress.call
      end
    ensure
      Thread.current[:pretend] = prev_pretend if dry_run
    end
    update_progress.call(true)
    app.speaker.speak_up("music organize: #{progress['organized']} file(s) organized, #{progress['skipped']} already in place (destination #{destination})#{' [DRY-RUN]' if dry_run}", 0) if app.respond_to?(:speaker)
    { 'organized' => progress['organized'], 'skipped' => progress['skipped'], 'destination' => destination, 'dry_run' => dry_run }
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    { 'organized' => 0, 'skipped' => 0, 'destination' => destination }
  end

  # Targeted AcoustID pass over "bare" files — those with no usable artist or
  # title tag, which text matching (MusicBrainz/iTunes) cannot identify. Scans
  # +source+, fingerprints each bare file and reports it as identified /
  # low-confidence / unidentified. Dry-run by default: pure report, nothing is
  # written or moved. With --apply=1, each identified file first gets the
  # recovered tags STAMPED INTO IT (only_missing: an existing embedded tag is
  # never overwritten), and is then organized into the library. Writing before
  # organizing matters: the file's embedded tags are what organize trusts most,
  # so the fingerprint identification takes precedence over whatever junk the
  # parasite folder/file names would parse into. Low-confidence matches (score
  # under music.acoustid_min_score) are never written.
  def self.identify_untagged(source: nil, destination: nil, apply: false, write_tags: true)
    destination = (destination.to_s.strip.empty? ? MusicSearch.music_destination : destination.to_s)
    source = source.to_s.strip.empty? ? destination : source.to_s
    dry_run = !flag_true?(apply)
    report = { 'scanned' => 0, 'untagged' => 0, 'identified' => 0, 'low_confidence' => 0,
               'unidentified' => 0, 'written' => 0, 'organized' => 0, 'dry_run' => dry_run }
    return report unless File.exist?(source)

    unless acoustid_enabled?
      app.speaker.speak_up('music identify: AcoustID is disabled — set music.acoustid_key in conf.yml (free key: https://acoustid.org/new-application)', 0)
      return report
    end

    client = acoustid
    write_tags = flag_true?(write_tags)
    @album_artist_memo = {} # per-run: one ALBUMARTIST lookup per album folder
    files = audio_files(source)
    report['scanned'] = files.size
    bare = files.each_with_object({}) do |file, memo|
      tags = read_tags(file)
      memo[file] = tags unless present(tags[:artist]) && present(tags[:title])
    end
    report['untagged'] = bare.size
    app.speaker.speak_up("music identify: #{bare.size}/#{files.size} file(s) without artist/title under '#{source}' (min score #{client.min_score})#{' [DRY-RUN: report only, pass --apply=1 to write tags and organize]' if dry_run}", 0)

    bare.each do |file, embedded|
      result = client.identify(file)
      score = result[:score] ? format('%.2f', result[:score]) : '?'
      case result[:status]
      when :identified
        found = result[:tags]
        report['identified'] += 1
        app.speaker.speak_up("music identify: OK   (#{score}) '#{File.basename(file)}' -> #{found[:artist]} - #{found[:title]}#{" [#{found[:album]}]" unless found[:album].to_s.strip.empty?}", 0)
        if write_tags
          written = TagWriter.write_tags(file, found, only_missing: true, current: embedded,
                                         dry_run: dry_run, speaker: (app.speaker if app.respond_to?(:speaker)))
          report['written'] += 1 unless written.empty?
        end
        unless dry_run
          dest = organize_file(file, destination, folder_name: File.basename(File.dirname(file)),
                                                  dry_run: false, write_tags: write_tags)
          report['organized'] += 1 if dest
        end
      when :low_confidence
        report['low_confidence'] += 1
        app.speaker.speak_up("music identify: LOW  (#{score} < #{client.min_score}) '#{file}' — match not trusted, left untouched", 0)
      else
        report['unidentified'] += 1
        app.speaker.speak_up("music identify: MISS '#{file}' — no fingerprint match", 0)
      end
    end
    app.speaker.speak_up("music identify: #{report['identified']} identified, #{report['low_confidence']} low-confidence, #{report['unidentified']} unidentified — #{report['written']} tagged, #{report['organized']} organized#{' [DRY-RUN]' if dry_run}", 0)
    report
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    report || { 'dry_run' => true }
  end

  # Organize a single audio file. Returns the destination path when the library
  # changed (file linked, moved or deduplicated), nil when nothing was done.
  def self.organize_file(path, destination_root, folder_name: nil, dry_run: true, compilation: false, musicbrainz_mode: nil, write_tags: false)
    ext = FileUtils.get_extension(path).to_s.downcase
    return nil unless EXTENSIONS_TYPE[:audio].include?(ext)

    destination_root = fs_utf8(File.expand_path(destination_root.to_s))
    path = fs_utf8(File.expand_path(fs_utf8(path)))
    in_place = path.start_with?(destination_root + '/')

    original_tags = read_tags(path)
    tags = original_tags
    # For files already inside the library, the Artist/Album directory structure
    # is authoritative when tags are missing — without this, a re-organize run
    # with unreadable tags would demote well-placed files to 'Unknown Artist'.
    tags = merge_tags(tags, tags_from_library_path(path, destination_root)) if in_place
    tags = complete_tags(merge_tags(tags, parse_from_names(File.basename(path, ".#{ext}"), folder_name)), path,
                         mode: musicbrainz_mode || resolve_musicbrainz_mode)
    # STAGING GUARD: a file whose tags are still incomplete after every lookup
    # (MusicBrainz, then iTunes) must NEVER leave the staging area — filing it
    # would pollute the library with 'Unknown Artist' entries. It stays put for
    # a later retry; only fully-tagged files may enter the library. In-place
    # files are exempt (their path already encodes artist/album authority).
    unless in_place || tags_complete?(tags)
      app.speaker.speak_up("music organize: '#{File.basename(path)}' tags incomplete after lookups, left in staging")
      return nil
    end

    # INTERNAL TAG WRITING (organize --write_tags=1): stamp the looked-up
    # metadata into the file itself so Navidrome and other readers see clean
    # tags, not just a tidy folder tree. Fills only fields the file is missing
    # (existing curated tags are preserved). Runs before the move so the library
    # copy carries the tags, and also for already-in-place files (path == dest)
    # whose folder is fine but whose internal tags are incomplete. dry_run only
    # logs; real writes are gated behind --apply by the dry_run flag. Unsupported
    # formats (e.g. m4a with no tagger installed) are a silent no-op.
    if write_tags
      wt = tags.dup
      # ALBUMARTIST is the key Navidrome groups an album by. What matters is that
      # EVERY track of one album carries the SAME value, so the album shows up as
      # one -- the exact string ("Various Artists" or a single name) is
      # irrelevant. We therefore source it from MusicBrainz and, crucially,
      # resolve it ONCE PER ALBUM FOLDER (memoized), reusing that one value for
      # every track of the album -- otherwise a compilation, whose tracks each
      # carry a different track-artist, could get different MB answers and split
      # in Navidrome. only_missing keeps any existing ALBUMARTIST untouched.
      unless present(wt[:albumartist])
        wt[:albumartist] = album_artist_for(File.dirname(path), wt[:artist], wt[:album])
      end
      TagWriter.write_tags(path, wt, only_missing: true, current: original_tags,
                           dry_run: dry_run, speaker: (app.speaker if app.respond_to?(:speaker)))
    end


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
        # This copy inside the library is identical to one or more already-filed
        # ones. Deleting on both sides of a duplicate pair would wipe the track
        # entirely (A says "dup of B" and B says "dup of A"), so elect a single
        # deterministic survivor — the lexicographically smallest path among the
        # identical set — and only remove the current file when it is NOT that
        # survivor. This keeps exactly one copy no matter the visit order.
        identical_group = ([path] + exact_dups).uniq
        survivor = identical_group.min_by { |f| f.to_s }
        if path == survivor
          # Current file is the one we keep; leave it in place.
          return survivor
        end
        removed = remove_or_log(path, destination_root, dry_run: dry_run, reason: "identical to #{File.basename(survivor)}")
        prune_empty_dirs(File.dirname(path), destination_root) if removed && removed != :dry_run
        return survivor
      end
      # Incoming (from outside) is already present identically. The library copy
      # is authoritative, so the staging original is redundant: remove it (same
      # guards as the post-copy cleanup: only when applying, only a real file,
      # never a hardlink to the existing library copy). This drains the staging
      # on a re-run where everything is already filed.
      dup = exact_dups.first
      unless dry_run
        begin
          if !File.identical?(path, dup) && File.exist?(dup)
            File.delete(path)
            src_dir = File.dirname(path)
            Dir.rmdir(src_dir) if File.directory?(src_dir) && Dir.empty?(src_dir)
          end
        rescue => e
          app.speaker.tell_error(e, "staging cleanup skipped for already-present '#{path}'") rescue nil
        end
      end
      app.speaker.speak_up("music organize: '#{File.basename(path)}' already present identically, removed from staging") if Env.debug?
      return dup
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
      # STAGING CLEANUP: the library copy is authoritative, so remove the
      # source from the download staging once the copy is verified byte-size
      # identical. Only for real copies (cross-filesystem: library is on NFS,
      # staging on root fs, so File.link never shares an inode here) and only
      # when applying. A hardlink (same inode, links>1) is left alone. If the
      # copy looks wrong, we keep the source and log — never delete blindly.
      # NOTE: this assumes no live Soulseek share seeding from staging (sockseek
      # is a one-shot downloader, not a seeding client). See handoff note about
      # re-enabling P2P sharing from the library.
      unless dry_run
        begin
          same_inode = File.identical?(path, dest)
          if !same_inode && File.exist?(dest) && File.size(dest) == File.size(path)
            File.delete(path)
            # Remove the now-empty staging album folder (one level only; never
            # recurse up past it to avoid touching unrelated staging dirs).
            src_dir = File.dirname(path)
            Dir.rmdir(src_dir) if File.directory?(src_dir) && Dir.empty?(src_dir)
          elsif !same_inode
            app.speaker.speak_up("music organize: kept staging source '#{File.basename(path)}' (copy unverified)")
          end
        rescue => e
          app.speaker.tell_error(e, "staging cleanup skipped for '#{path}'") rescue nil
        end
      end
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
    # A leading numeric prefix is a track number (optionally disc-track like
    # "1-03" or a zero-padded position like "0152"), NEVER an artist. We accept
    # 1-4 digits so "0152 - Lasgo - Something" is track 152, not artist "0152".
    if (match = base.match(/\A(?:(\d{1,2})[-.])?\s*(\d{1,4})[\s._-]+(.+)\z/))
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
    # A purely-numeric artist/title is never real (a mis-parsed track number);
    # blank it so tags_complete? stays false and lookups/staging-guard kick in.
    tags[:artist] = '' if tags[:artist].to_s.strip.match?(/\A\d+\z/)
    tags[:title] = '' if tags[:title].to_s.strip.match?(/\A\d+\z/)
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
      FileInfo.new(path).audio_quality_score
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
  def self.consolidate_compilations(destination: nil, apply: false)
    root = fs_utf8(File.expand_path((destination.to_s.strip.empty? ? MusicSearch.music_destination : destination.to_s)))
    dry_run = !flag_true?(apply)
    return { 'compilations' => 0, 'files' => 0, 'review' => 0, 'destination' => root, 'dry_run' => dry_run } unless File.directory?(root)

    review = []
    groups = scattered_compilation_groups(audio_files(root), review)
    total = groups.sum { |g| g['files'].size }
    app.speaker.speak_up("music consolidate_compilations: #{groups.size} compilation(s) confirmed by MusicBrainz, #{total} track(s); #{review.size} candidate(s) to review#{' [DRY-RUN: no changes, pass --apply=1 to act]' if dry_run}", 0) if app.respond_to?(:speaker)

    va = compilation_artist
    relocated = 0
    groups.each do |group|
      if dry_run
        app.speaker.speak_up("music consolidate_compilations [DRY-RUN]: '#{group['album']}' (MB: various artists) — #{group['files'].size} track(s) from #{group['dirs']} folder(s), #{group['artists']} artist(s) -> '#{File.join(va, group['album'])}'", 0) if app.respond_to?(:speaker)
        relocated += group['files'].size
      else
        group['files'].each do |file|
          dest = organize_file(file, root, folder_name: File.basename(File.dirname(file)), dry_run: false, compilation: true)
          relocated += 1 if dest
        end
      end
    end

    # Candidates MusicBrainz could not confirm/deny: never merged automatically,
    # surfaced here so the user can decide by hand.
    review.each do |cand|
      app.speaker.speak_up("music consolidate_compilations [REVIEW]: '#{cand['album']}' — #{cand['files'].size} track(s), #{cand['artists']} artist(s) across #{cand['dirs']} folder(s): MusicBrainz inconclusive, left as-is", 0) if app.respond_to?(:speaker)
    end

    app.speaker.speak_up("music consolidate_compilations: #{groups.size} compilation(s), #{relocated} track(s) #{dry_run ? 'to relocate' : 'relocated'}; #{review.size} to review (destination #{root})#{' [DRY-RUN]' if dry_run}", 0) if app.respond_to?(:speaker)
    { 'compilations' => groups.size, 'files' => relocated, 'review' => review.size, 'destination' => root, 'dry_run' => dry_run }
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    { 'compilations' => 0, 'files' => 0, 'review' => 0, 'destination' => root, 'dry_run' => !flag_true?(apply) }
  end

  # Library-wide scattered compilations, verified against MusicBrainz instead of
  # a hard-coded blocklist. Any album title shared by >= 2 distinct artists over
  # >= 2 directories is a *candidate*; we then ask MusicBrainz whether a genuine
  # Various Artists release of that title exists:
  #   :yes     -> real compilation, include it in the consolidation plan
  #   :no      -> homonymous single-artist albums, leave untouched
  #   :unknown -> MB could not decide -> collect into review[] for manual triage
  # The optional review accumulator (an array) receives the :unknown candidates.
  def self.scattered_compilation_groups(files, review = nil)
    index = Hash.new { |h, k| h[k] = [] }
    Array(files).each do |file|
      tags = read_tags(file)
      base = norm_album_base(tags[:album])
      next if base.strip.empty?

      key = norm_tag(base)
      next if key.empty?

      index[key] << { file: file, album: base, artist: norm_tag(tags[:artist]), dir: File.dirname(file) }
    end

    index.filter_map do |_key, entries|
      artists = entries.map { |e| e[:artist] }.reject(&:empty?).uniq
      dirs = entries.map { |e| e[:dir] }.uniq
      # A single-artist album (even across dirs) or a single folder is not a
      # scattered multi-artist compilation candidate.
      next unless artists.size >= 2 && dirs.size >= 2

      album = most_common(entries.map { |e| e[:album] })
      verdict = compilation_verdict(album)
      case verdict
      when :yes
        { 'album' => album, 'files' => entries.map { |e| e[:file] }.sort,
          'artists' => artists.size, 'dirs' => dirs.size }
      when :unknown
        if review.is_a?(Array)
          review << { 'album' => album, 'artists' => artists.size, 'dirs' => dirs.size,
                      'files' => entries.map { |e| e[:file] }.sort }
        end
        nil
      else # :no -> homonymous single-artist albums, skip
        nil
      end
    end
  rescue StandardError => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    []
  end

  # Ask MusicBrainz whether an album title corresponds to a real Various Artists
  # release. Falls back to :unknown (flag for review) when MB is unavailable or
  # the lookup is disabled, so we never silently merge on a guess.
  def self.compilation_verdict(album)
    mb = musicbrainz
    return :unknown unless mb.respond_to?(:compilation_release)

    mb.compilation_release(album)
  rescue StandardError
    :unknown
  end

  def self.most_common(values)
    values.group_by(&:itself).max_by { |_v, occurrences| occurrences.size }&.first.to_s
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
    # NB: reading tags never writes anything, so it stays active even under
    # Env.pretend? (a dry-run still needs to scan to compute its plan).
    # Scan cache: reading tags goes through mediainfo (an external process per
    # file), which dominates a full-library scan over NFS. Key the cached tags
    # by path and invalidate on size/mtime change, so an unchanged file is never
    # re-scanned. First scan is normal; subsequent passes skip mediainfo for
    # untouched files.
    cache = scan_cache
    begin
      stat = File.stat(path)
      sig = "#{stat.size}:#{stat.mtime.to_i}"
    rescue StandardError
      stat = nil
      sig = nil
    end

    if cache && sig
      cached = cache.get(path)
      if cached.is_a?(Hash) && cached['sig'] == sig && cached['tags'].is_a?(Hash)
        return symbolize_tags(cached['tags'])
      end
    end

    tags = FileInfo.new(path).audio_tags
    if cache && sig && tags.is_a?(Hash)
      cache.set(path, 'sig' => sig, 'tags' => stringify_tags(tags)) rescue nil
    end
    tags
  rescue
    {}
  end

  def self.scan_cache
    return @scan_cache[1] if defined?(@scan_cache) && @scan_cache && @scan_cache[0] == app.config_dir

    c = JsonDiskCache.new(
      dir: File.join(app.config_dir, 'cache', 'scan'),
      ttl_days: 3650, # effectively permanent; correctness comes from size+mtime, not TTL
      speaker: (app.respond_to?(:speaker) ? app.speaker : nil)
    )
    @scan_cache = [app.config_dir, c]
    c
  rescue StandardError
    nil
  end

  def self.stringify_tags(tags)
    tags.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
  end

  # Fill missing artist/album/title from external metadata providers when tags
  # and name parsing left gaps. AcoustID (acoustic fingerprint) is tried first
  # because it identifies a track even without any usable tags/name; MusicBrainz
  # text search then fills any remaining gap. Existing tags always take
  # precedence over looked-up values.
  #
  # `mode` governs the (slow, ~1 req/s, timeout-prone) MusicBrainz call:
  #   - 'auto' (default): a fully-tagged file is organized straight from its own
  #     tags with NO network lookup — the fast path for the ~90% already tagged
  #     by sockseek. MusicBrainz is queried only when tags are still incomplete.
  #   - 'never': MusicBrainz is never queried (organize best-effort from tags).
  #   - 'always': MusicBrainz is queried even when tags look complete.
  # AcoustID keeps its own enable flag (it needs a key) and is unaffected.
  def self.complete_tags(tags, path = nil, mode: 'auto')
    return tags if mode != 'always' && tags_complete?(tags)

    if path && acoustid_enabled? && !(present(tags[:artist]) && present(tags[:title]))
      client = acoustid
      found = client&.lookup(path)
      tags = merge_tags(tags, symbolize_tags(found)) if found && !found.empty?
      return tags if mode != 'always' && tags_complete?(tags)
    end

    if mode != 'never'
      client = musicbrainz
      if client
        found = client.complete(artist: tags[:artist], album: tags[:album], title: tags[:title], track: tags[:track])
        tags = merge_tags(tags, symbolize_tags(found)) if found && !found.empty?
      end
      # Secondary provider: when MusicBrainz is unavailable (rate-limited,
      # IP-blocked) or returned nothing useful, try the keyless iTunes Search
      # API before giving up — an incomplete file never leaves staging.
      unless tags_complete?(tags)
        fallback = itunes
        if fallback
          found = fallback.complete(artist: tags[:artist], album: tags[:album], title: tags[:title], track: tags[:track])
          tags = merge_tags(tags, symbolize_tags(found)) if found && !found.empty?
        end
      end
    end
    tags
  rescue
    tags
  end

  # A file is ready to organize straight from its own tags — no metadata lookup —
  # when artist (album-artist preferred; FileInfo reads album_performer first),
  # album, title and track number are all present. Disc number is best-effort
  # (we cannot tell per-file whether the album is multi-disc) and year, while
  # desirable, is non-blocking.
  def self.tags_complete?(tags)
    return false if tags[:artist].to_s.strip.match?(/\A\d+\z/) # numeric = mis-parsed track no.
    return false if tags[:title].to_s.strip.match?(/\A\d+\z/)
    present(tags[:artist]) && present(tags[:album]) && present(tags[:title]) && present(tags[:track])
  end

  MUSICBRAINZ_MODES = %w[always auto never].freeze
  # Resolve the MusicBrainz policy: an explicit CLI value wins, then
  # music.musicbrainz_mode, else 'auto' when MusicBrainz is enabled (the legacy
  # music.musicbrainz:false still disables it entirely, mapping to 'never').
  def self.resolve_musicbrainz_mode(override = nil)
    candidate = override.to_s.strip.downcase
    return candidate if MUSICBRAINZ_MODES.include?(candidate)

    configured = (app.config['music'] && app.config['music']['musicbrainz_mode']).to_s.strip.downcase
    return configured if MUSICBRAINZ_MODES.include?(configured)

    musicbrainz_enabled? ? 'auto' : 'never'
  rescue StandardError
    'auto'
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

  # Confidence floor for AcoustID matches (music.acoustid_min_score). Below it a
  # match is discarded rather than risk writing a wrong identification into the
  # library. nil defers to the client default (AcoustidApi::MIN_SCORE).
  def self.acoustid_min_score
    value = (app.config['music'] && app.config['music']['acoustid_min_score']).to_s.strip
    value.empty? ? nil : value.to_f
  rescue
    nil
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
      :acoustid => AcoustidApi.new(api_key: acoustid_key, speaker: speaker, cache: cache, min_score: acoustid_min_score),
      :itunes => ItunesSearchApi.new(speaker: speaker, cache: cache)
    }]
    @metadata_clients[1]
  rescue
    nil
  end

  # Album artist resolved ONCE per album folder and cached for the whole run, so
  # every track of an album gets an identical ALBUMARTIST (the thing that makes
  # Navidrome show it as a single album). First track of a folder triggers the
  # MusicBrainz lookup; siblings reuse the memoized value. Falls back to the
  # (first track's) artist when MB has no match, and that fallback is memoized
  # too so it stays consistent across the album.
  def self.album_artist_for(album_dir, artist_hint, album)
    @album_artist_memo ||= {}
    return @album_artist_memo[album_dir] if @album_artist_memo.key?(album_dir)

    mb_aa = (album_artist_from_mb(artist_hint, album) if resolve_musicbrainz_mode != 'never')
    @album_artist_memo[album_dir] = present(mb_aa) ? mb_aa : artist_hint.to_s
  end

  # Album artist per MusicBrainz for a given (artist, album): a release lookup
  # whose result is cached by query, so every track of one album triggers at
  # most one network call. Returns '' when MB is unavailable or has no match.
  def self.album_artist_from_mb(artist, album)
    return '' unless present(album)
    client = musicbrainz
    return '' unless client
    found = client.complete(artist: artist.to_s, album: album.to_s, title: '', track: '')
    found.is_a?(Hash) ? found[:albumartist].to_s : ''
  rescue StandardError
    ''
  end

  def self.musicbrainz
    metadata_clients&.dig(:musicbrainz)
  end

  def self.acoustid
    metadata_clients&.dig(:acoustid)
  end

  def self.itunes
    metadata_clients&.dig(:itunes)
  end

  def self.link_or_copy(source, dest)
    # Honour the dry-run mode: never write in pretend (this uses raw File/IO,
    # not the FileUtils shims that are already pretend-gated).
    return if Env.pretend?

    File.link(source, dest)
  rescue SystemCallError
    IO.copy_stream(source, dest)
  end

  # --- Library-wide de-duplication (maintenance pass) -----------------------
  #
  # organize_file only ever removes a byte-identical copy in the SAME album
  # folder, so the common case -- the same recording present in several
  # editions/folders at different qualities (mp3 next to flac, 16-bit next to
  # 24-bit, a single next to a box set) -- was never collapsed. This one-shot
  # pass groups the WHOLE library by recording identity and keeps the single
  # best-quality copy of each, moving the rest to the reversible trash. Dry-run
  # by default; pass --apply=1 to act. Reuses the organize trash + name/stream
  # quality scoring, so music.organize_trash config and reversibility apply.
  #
  # Identity key = (primary artist, base title, version signature). Neutral
  # suffixes (remaster/mono/radio edit/...) are stripped so a remaster collapses
  # with the original; distinct-version markers (live/remix/acoustic/extended/
  # instrumental/...) are kept -- with their full qualifier (venue/date) -- so
  # two different live takes never merge but two copies of one take do. Within a
  # key, entries are clustered by duration (a 3:30 cut never merges with a 5:00
  # version), and any nude-titled cluster mixing a live/session album with a
  # studio album is skipped as too risky to auto-resolve.
  def self.dedupe(destination: nil, apply: false)
    root = fs_utf8(File.expand_path((destination.to_s.strip.empty? ? MusicSearch.music_destination : destination.to_s)))
    dry_run = !flag_true?(apply)
    return { 'groups' => 0, 'trashed' => 0, 'destination' => root, 'dry_run' => dry_run } unless File.directory?(root)

    files = audio_files(root)
    app.speaker.speak_up("music dedupe: scanning #{files.size} file(s) under '#{root}'#{' [DRY-RUN: no deletions, pass --apply=1 to act]' if dry_run}", 0) if app.respond_to?(:speaker)

    index = Hash.new { |h, k| h[k] = [] }
    files.each do |f|
      meta = dedupe_scan(f)
      tags = meta[:tags]
      artist = dedupe_primary_artist(tags)
      base = dedupe_base_title(tags[:title])
      next if artist.empty? || base.empty? # untagged files are never grouped
      sig = dedupe_version_sig(tags[:title])
      index[[artist, base, sig]] << { :path => f, :tags => tags, :score => meta[:score].to_i, :dur => meta[:duration].to_i, :sig => sig }
    end

    groups = 0
    trashed = 0
    index.each_value do |entries|
      next if entries.size < 2
      dedupe_duration_clusters(entries).each do |cluster|
        next if cluster.size < 2
        next if dedupe_risky_live?(cluster)
        survivor = cluster.max_by { |e| [e[:score], (lossless?(e[:path]) ? 1 : 0), (e[:tags][:year].to_s[/\d{4}/] || '0').to_i, (File.size(e[:path]) rescue 0)] }
        losers = cluster.reject { |e| e.equal?(survivor) }
        # Never trash a lossless copy in favour of a lossy survivor.
        losers = losers.reject { |e| lossless?(e[:path]) && !lossless?(survivor[:path]) }
        next if losers.empty?
        groups += 1
        losers.each do |e|
          r = remove_or_log(e[:path], root, dry_run: dry_run, reason: "dedupe: superseded by #{File.basename(survivor[:path])}")
          next unless r
          trashed += 1
          prune_empty_dirs(File.dirname(e[:path]), root) unless dry_run || r == :dry_run
        end
      end
    end

    app.speaker.speak_up("music dedupe: #{groups} duplicate group(s), #{trashed} file(s) #{dry_run ? 'to trash' : 'trashed'} (destination #{root})#{' [DRY-RUN]' if dry_run}", 0) if app.respond_to?(:speaker)
    { 'groups' => groups, 'trashed' => trashed, 'destination' => root, 'dry_run' => dry_run }
  rescue StandardError => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    { 'groups' => 0, 'trashed' => 0, 'destination' => root, 'dry_run' => !flag_true?(apply) }
  end

  # One MediaInfo pass per file -> { tags:, score:, duration: (seconds) },
  # cached by size:mtime under a dedicated key so re-runs skip the rescan.
  def self.dedupe_scan(path)
    cache = scan_cache
    sig = begin
      st = File.stat(path)
      "#{st.size}:#{st.mtime.to_i}"
    rescue StandardError
      nil
    end
    if cache && sig
      cached = cache.get("dedupe:#{path}")
      if cached.is_a?(Hash) && cached['sig'] == sig
        return { :tags => symbolize_tags(cached['tags'] || {}), :score => cached['score'].to_i, :duration => cached['dur'].to_i }
      end
    end
    fi = FileInfo.new(path)
    tags = (fi.audio_tags rescue {})
    tags = {} unless tags.is_a?(Hash)
    score = ((fi.audio_quality_score rescue nil) || name_quality_score(path)).to_i
    dur = 0
    begin
      raw = fi.media_info && fi.media_info.audio && fi.media_info.audio.duration
      dur = (raw.to_f / 1000.0).round if raw
    rescue StandardError
      dur = 0
    end
    (cache.set("dedupe:#{path}", 'sig' => sig, 'tags' => stringify_tags(tags), 'score' => score, 'dur' => dur) if cache && sig) rescue nil
    { :tags => tags, :score => score, :duration => dur }
  end

  DEDUPE_DISTINCT = /\b(remix(?:es)?|live|acoustic|unplugged|extended|instrumental|dub|demo|reprise|sessions?|karaoke|acappella|bootleg|rework|mashup|tracking mix|backing track|rough|vip|flip)\b|12"|7"|re-?edit/i
  DEDUPE_NEUTRAL = /\b(remaster(?:ed)?|digital remaster(?:ed)?|mono|stereo|radio edit|single version|album version|original version|original mix|original|explicit|clean|bonus track|deluxe|expanded|anniversary|edition|version|mix)\b/i
  DEDUPE_LIVE_ALBUM = /\b(live|unplugged|concert|en public|en concert|acoustic|sessions?|bbc|peel|on stage|in concert|au caveau|tour)\b/i
  DEDUPE_YEAR = /\b(?:19|20)\d{2}\b/

  def self.dedupe_ascii(str)
    str.to_s.unicode_normalize(:nfkd).chars.reject { |c| c =~ /\p{Mn}/ }.join
  rescue StandardError
    str.to_s
  end

  def self.dedupe_norm(str)
    dedupe_ascii(str.to_s.downcase).gsub(/[^a-z0-9]+/, ' ').strip.gsub(/\s+/, ' ')
  end

  def self.dedupe_primary_artist(tags)
    a = tags[:artist].to_s
    a = tags[:albumartist].to_s if a.strip.empty?
    part = a.split(/[,;\/&]|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b|\bvs\.?/i).first
    dedupe_norm(part)
  end

  def self.dedupe_base_title(title)
    t = dedupe_ascii(title.to_s.downcase)
    t = t.gsub(/\([^)]*\)|\[[^\]]*\]/, ' ')
    t = t.sub(/\s-\s.*\z/, ' ')
    t = t.gsub(DEDUPE_NEUTRAL, ' ').gsub(DEDUPE_YEAR, ' ')
    t.gsub(/[^a-z0-9]+/, ' ').strip.gsub(/\s+/, ' ')
  end

  def self.dedupe_version_sig(title)
    t = dedupe_ascii(title.to_s.downcase)
    return '' unless t =~ DEDUPE_DISTINCT
    quals = t.scan(/\(([^)]*)\)|\[([^\]]*)\]/).flatten.compact.join(' ')
    tail = (t[/\s-\s(.*)\z/, 1] || '')
    src = "#{quals} #{tail}".strip
    src = t if src.empty?
    src = src.gsub(DEDUPE_NEUTRAL, ' ').gsub(DEDUPE_YEAR, ' ')
    src.gsub(/[^a-z0-9]+/, ' ').strip.gsub(/\s+/, ' ')
  end

  # Single-linkage clustering on duration (seconds), anchored on the cluster
  # minimum so a long tail of growing durations cannot chain-merge. Files with
  # unknown duration (0) are each left in their own singleton (never merged).
  def self.dedupe_duration_clusters(entries)
    timed = entries.select { |e| e[:dur].to_i > 0 }.sort_by { |e| e[:dur] }
    clusters = []
    cur = []
    timed.each do |e|
      if cur.empty?
        cur = [e]
        next
      end
      d0 = cur.first[:dur]
      tol = [[0.02 * [e[:dur], d0].max, 1.5].max, 4.0].min
      if (e[:dur] - d0) <= tol
        cur << e
      else
        clusters << cur
        cur = [e]
      end
    end
    clusters << cur unless cur.empty?
    entries.select { |e| e[:dur].to_i <= 0 }.each { |e| clusters << [e] }
    clusters
  end

  # A nude-titled cluster mixing a live/session-named album with a studio album
  # is ambiguous (the "studio vs live" trap) -- skip it, never auto-trash.
  def self.dedupe_risky_live?(cluster)
    return false unless cluster.first[:sig].to_s.empty?
    albums = cluster.map { |e| e[:tags][:album].to_s }
    albums.any? { |a| a =~ DEDUPE_LIVE_ALBUM } && albums.any? { |a| a !~ DEDUPE_LIVE_ALBUM }
  end
end

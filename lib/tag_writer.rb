# frozen_string_literal: true

require 'open3'

# Writes the handful of tags organize needs to fix "compilation exploded into
# one-track albums" in Navidrome: ALBUMARTIST and the iTunes COMPILATION flag.
#
# Tags are written in place by shelling out to the format's native tagger
# (metaflac for FLAC, mid3v2/mutagen for MP3) with argument ARRAYS — never a
# shell string — so accented/quoted artist and album names cannot break out.
# When the required binary is missing the writer is simply a no-op, so a host
# without the taggers still organizes (folders) without crashing.
module TagWriter
  COMPILATION_ARTIST = 'Various Artists'

  module_function

  # Can we stamp tags for this file's format on this host?
  def available?(path)
    !binary_for(path).nil?
  end

  # Stamp ALBUMARTIST (band) + COMPILATION=1 on +path+. Returns true when written
  # (or, in dry_run, when it *would* be), false when unsupported or on error.
  # dry_run only logs; the caller gates real writes behind --apply.
  def stamp_compilation(path, album_artist: COMPILATION_ARTIST, dry_run: true, speaker: nil)
    cmds = compilation_commands(path, album_artist)
    return false if cmds.empty?

    if dry_run
      speaker&.speak_up("tag [DRY-RUN]: would set ALBUMARTIST='#{album_artist}' + COMPILATION=1 on '#{path}'", 0)
      return true
    end

    ok = cmds.all? { |cmd| run(cmd, speaker) }
    speaker&.speak_up("tag: set ALBUMARTIST='#{album_artist}' + COMPILATION=1 on '#{path}'", 0) if ok
    ok
  end

  # The exact tagger invocation(s), as argument arrays, or [] when unsupported.
  # Exposed for unit tests so the command shape is verified without running it.
  def compilation_commands(path, album_artist = COMPILATION_ARTIST)
    ext = File.extname(path.to_s).sub('.', '').downcase
    bin = binary_for(path)
    return [] unless bin

    case ext
    when 'flac'
      # metaflac: replace (not append) the tags, then set them.
      [[bin,
        '--remove-tag=ALBUMARTIST', '--remove-tag=COMPILATION',
        "--set-tag=ALBUMARTIST=#{album_artist}", '--set-tag=COMPILATION=1',
        path.to_s]]
    when 'mp3'
      # mid3v2: TPE2 is the album-artist/band frame; TCMP is the iTunes
      # compilation flag. Two invocations because mid3v2 takes one frame per run.
      [[bin, '--TPE2', album_artist.to_s, path.to_s],
       [bin, '--TCMP', '1', path.to_s]]
    else
      []
    end
  end

  # --- Full internal-tag writing (organize --write-tags) -------------------
  #
  # Canonical tag set organize can stamp into the file itself, so Navidrome and
  # any other reader see clean metadata (not just a tidy folder tree). Maps the
  # organizer's tag hash keys to the on-disk frames/fields for each format.
  #
  #   :artist :title :album :albumartist :track :disc :year
  #
  # only_missing:true (default) writes a field ONLY when the file's current value
  # for it is blank, so an existing, curated tag is never clobbered. Pass
  # only_missing:false to let the looked-up value win (MB/iTunes as source of
  # truth). +current+ is the file's existing tag hash (same keys); when omitted
  # nothing is treated as present, i.e. everything missing is written.
  #
  # Returns the list of field keys actually written (or, in dry_run, that would
  # be); [] when the format is unsupported on this host (graceful no-op, e.g.
  # m4a with no tagger installed) or nothing needed writing.
  CONTENT_KEYS = %i[artist title album albumartist track disc year].freeze

  def write_tags(path, tags, only_missing: true, current: {}, dry_run: true, speaker: nil)
    bin = binary_for(path)
    return [] unless bin # unsupported format on this host -> no-op

    cur = current || {}
    to_write = CONTENT_KEYS.select do |k|
      v = tags[k]
      next false unless present_val(v)
      only_missing ? !present_val(cur[k]) : true
    end
    return [] if to_write.empty?

    cmds = content_commands(path, tags, to_write)
    return [] if cmds.empty?

    if dry_run
      speaker&.speak_up("tag [DRY-RUN]: would write #{to_write.join(', ')} on '#{path}'", 0)
      return to_write
    end

    ok = cmds.all? { |cmd| run(cmd, speaker) }
    speaker&.speak_up("tag: wrote #{to_write.join(', ')} on '#{path}'", 0) if ok
    ok ? to_write : []
  end

  # Build the tagger invocation(s) (argument arrays) to set +keys+ from +tags+.
  # Exposed for unit tests so the command shape is verified without running it.
  def content_commands(path, tags, keys)
    ext = File.extname(path.to_s).sub('.', '').downcase
    bin = binary_for(path)
    return [] unless bin

    case ext
    when 'flac'
      args = [bin]
      keys.each do |k|
        vorbis = FLAC_FIELDS[k]
        next unless vorbis && present_val(tags[k])
        args << "--remove-tag=#{vorbis}"
      end
      keys.each do |k|
        vorbis = FLAC_FIELDS[k]
        next unless vorbis && present_val(tags[k])
        args << "--set-tag=#{vorbis}=#{normalize_val(k, tags[k])}"
      end
      args.length > 1 ? [args + [path.to_s]] : []
    when 'mp3'
      # mid3v2 takes one frame per invocation.
      keys.filter_map do |k|
        frame = ID3_FRAMES[k]
        next unless frame && present_val(tags[k])
        [bin, frame, normalize_val(k, tags[k]).to_s, path.to_s]
      end
    else
      []
    end
  end

  # Vorbis comment field names (FLAC / metaflac).
  FLAC_FIELDS = {
    artist: 'ARTIST', title: 'TITLE', album: 'ALBUM', albumartist: 'ALBUMARTIST',
    track: 'TRACKNUMBER', disc: 'DISCNUMBER', year: 'DATE'
  }.freeze

  # mid3v2 long-option flags per frame (MP3 / ID3v2).
  ID3_FRAMES = {
    artist: '--TPE1', title: '--TIT2', album: '--TALB', albumartist: '--TPE2',
    track: '--TRCK', disc: '--TPOS', year: '--TDRC'
  }.freeze

  # track/disc are stored bare (the number only); everything else as-is.
  def normalize_val(key, val)
    case key
    when :track, :disc
      n = val.to_s[/\d+/]
      n ? n.to_i.to_s : '' # bare number, no leading zeros (padding is for filenames)
    else val.to_s
    end
  end

  def present_val(v)
    !v.nil? && !v.to_s.strip.empty?
  end

  def binary_for(path)

    case File.extname(path.to_s).sub('.', '').downcase
    when 'flac' then which('metaflac')
    when 'mp3' then which('mid3v2')
    end
  end

  # Locate an executable on PATH without invoking a shell.
  def which(bin)
    return @which_cache[bin] if defined?(@which_cache) && @which_cache&.key?(bin)

    @which_cache ||= {}
    found = ENV['PATH'].to_s.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, bin) }
                       .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
    @which_cache[bin] = found
  end

  def run(cmd, speaker)
    _out, err, status = Open3.capture3(*cmd)
    return true if status.success?

    speaker&.speak_up("tag: #{File.basename(cmd.first)} failed (#{err.to_s.lines.last.to_s.strip})", 0)
    false
  rescue StandardError => e
    speaker&.speak_up("tag: #{e.class}: #{e.message}", 0)
    false
  end
end

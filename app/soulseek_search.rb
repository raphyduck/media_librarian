# frozen_string_literal: true

require 'csv'
require 'open3'
require 'tmpdir'

# Soulseek fallback for music the BitTorrent trackers do not carry.
#
# import_csv searches trackers first; whatever it cannot find (or would only
# find as a near-dead release) is handed here. This wraps sockseek
# (fiso64/sockseek, .NET 8) — a non-interactive Soulseek batch downloader — run
# once per batch of misses. sockseek downloads into the existing music staging
# folder (its config output-dir must match music.staging); the results are then
# filed into music_destination with MusicLibrary.organize, so nothing goes
# through the torrents table / Deluge.
#
# Configuration (conf.yml, all optional — the fallback is simply inactive when
# the binary or config file is missing, so a plain install never breaks the
# tracker import):
#
#   music:
#     soulseek:
#       enabled: true
#       binary:  /home/raph/bin/sockseek/sockseek
#       config:  /home/raph/.config/sockseek/sockseek.conf  # holds credentials, never in git
#       pref_format: flac
#
# The credentials live only in the sockseek config file on the server (outside
# git); this class never reads, logs, or stores them.
class SoulseekSearch
  include MediaLibrarian::AppContainerSupport

  DEFAULT_PREF_FORMAT = 'flac'
  DEFAULT_BINARY = '~/bin/sockseek/sockseek'
  DEFAULT_CONFIG = '~/.config/sockseek/sockseek.conf'

  # sockseek writes a per-entry index (_index.sldl, an sldl-format CSV) whose
  # `state` column tells us what happened. 1 = Downloaded, 3 = AlreadyExists —
  # both count as "obtained"; anything else (2 = Failed, 4 = NotFound, 0 = None)
  # is a miss.
  INDEX_SUCCESS_STATES = %w[1 3].freeze

  class << self
    # The fallback is usable only when explicitly enabled (default on) and the
    # binary + config file both exist. Any error here disables it silently.
    def available?
      return false unless enabled?

      File.file?(binary_path) && File.file?(config_path)
    rescue StandardError
      false
    end

    # entries: array of { artist:, title: | album: } (string or symbol keys).
    # Returns a report hash: { 'attempted', 'downloaded', 'failed',
    # 'downloaded_entries', 'failed_entries', 'destination' }, where the *_entries
    # are the original queries so the caller can reconcile its own report.
    # album_job:true fetches whole albums instead of individual tracks: sockseek
    # runs in --album mode with --strict-album-quality (the WHOLE album must meet
    # the preferred format), and the input CSV carries Artist,Album only. Used by
    # the caller for releases with several liked tracks or for a quality upgrade.
    def fetch(entries:, quality: DEFAULT_PREF_FORMAT, album_job: false)
      list = normalize_entries(entries)
      return empty_report(list.size) unless available?
      return empty_report(0) if list.empty?

      Dir.mktmpdir('sockseek') do |dir|
        csv_path = File.join(dir, 'input.csv')
        index_path = File.join(dir, 'index.sldl')
        write_input_csv(csv_path, list, album_job)

        cmd = build_command(csv_path: csv_path, index_path: index_path, quality: quality, album_job: album_job)
        role = (MusicSearch.soulseek_primary? ? 'primary' : 'fallback') rescue 'primary'
        speak "Soulseek (#{role}): handing #{list.size} #{album_job ? 'album(s)' : 'release(s)'} to sockseek"
        _out, err, status = Open3.capture3(*cmd)
        unless status.success?
          last = err.to_s.lines.last.to_s.strip
          speak "sockseek exited #{status.exitstatus}#{" (#{last})" unless last.empty?}"
        end

        # sockseek dropped files straight into the staging folder outside Deluge,
        # so the Execute-plugin hook never fires — file whatever landed there
        # explicitly. Done unconditionally (not gated on the parsed index) so a
        # sockseek index-format change can never leave downloads unfiled.
        organize_staging

        downloaded, failed = classify(list, index_path)
        build_report(list, downloaded, failed)
      end
    rescue StandardError => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
      empty_report(Array(entries).size)
    end

    private

    def soulseek_config
      cfg = app.config['music'] && app.config['music']['soulseek']
      cfg.is_a?(Hash) ? cfg : {}
    rescue StandardError
      {}
    end

    def enabled?
      value = soulseek_config['enabled']
      value.nil? ? true : (value != false && value.to_s.strip.downcase != 'false')
    end

    def binary_path
      configured = soulseek_config['binary'].to_s.strip
      File.expand_path(configured.empty? ? DEFAULT_BINARY : configured)
    end

    def config_path
      configured = soulseek_config['config'].to_s.strip
      File.expand_path(configured.empty? ? DEFAULT_CONFIG : configured)
    end

    # Preferred (not required) format: config wins, else derived from the
    # requested quality, else lossless. Kept as a *preference* so rare titles
    # shared only as MP3 are still fetched rather than skipped.
    def pref_format(quality)
      configured = soulseek_config['pref_format'].to_s.strip
      return configured unless configured.empty?
      return 'mp3' if quality.to_s.downcase.include?('mp3')

      DEFAULT_PREF_FORMAT
    end

    # sockseek v3 flags (verified against v3.0.3 --help):
    #   --input-type csv / --input <file>  : batch input
    #   --config <file>                    : holds the Soulseek credentials
    #   --pref-format <fmt>                : soft preference (not --format, which requires it)
    #   --skip-music-dir <dir>            : don't re-fetch what the library already has
    #   --no-progress                     : clean captured output
    #   --index-path <file>               : per-run result index
    # Skipping already-downloaded tracks is the v3 default (the opt-out is
    # --no-skip-existing), so no flag is needed. No --number (that truncates an
    # album to n tracks) and never --interactive (fully automatic). The CSV
    # carries an Album column, so sockseek searches albums without --song.
    def build_command(csv_path:, index_path:, quality:, album_job: false)
      cmd = [
        binary_path,
        '--input-type', 'csv',
        '--input', csv_path,
        '--config', config_path,
        '--pref-format', pref_format(quality),
        '--skip-music-dir', MusicSearch.music_destination,
        '--no-progress',
        '--index-path', index_path
      ]
      # --album: fetch the whole album; --strict-album-quality: require every track
      # in the album folder to satisfy the preferred format.
      cmd.concat(['--album', '--strict-album-quality']) if album_job
      cmd
    end

    def normalize_entries(entries)
      Array(entries).filter_map do |entry|
        h = symbolize(entry)
        artist = h[:artist].to_s.strip
        title = h[:title].to_s.strip
        album = h[:album].to_s.strip
        next if artist.empty? && title.empty? && album.empty?

        query = h[:query].to_s.strip
        query = [artist, album, title].reject(&:empty?).join(' ') if query.empty?
        { artist: artist, title: title, album: album, query: query }
      end
    end

    def symbolize(entry)
      return entry if entry.is_a?(Hash) && entry.keys.all? { |k| k.is_a?(Symbol) }
      return entry.each_with_object({}) { |(k, v), m| m[k.to_sym] = v } if entry.is_a?(Hash)

      {}
    end

    # CSV the way sockseek expects it for --input-type csv (mapped to
    # sartist/stitle/salbum). Ruby's CSV handles quoting/escaping of commas and
    # accents in artist/album names.
    def write_input_csv(path, list, album_job = false)
      headers = album_job ? %w[Artist Album] : %w[Artist Title Album]
      CSV.open(path, 'w', write_headers: true, headers: headers) do |csv|
        list.each do |e|
          csv << (album_job ? [e[:artist], e[:album]] : [e[:artist], e[:title], e[:album]])
        end
      end
    end

    # Match each input entry against the sockseek index by normalized
    # artist/album/title; an entry with a success state is downloaded, everything
    # else (including entries absent from the index) is a miss.
    def classify(list, index_path)
      rows = index_rows(index_path)
      downloaded = []
      failed = []
      list.each do |entry|
        row = rows.find { |r| index_row_matches?(r, entry) }
        if row && INDEX_SUCCESS_STATES.include?(row['state'].to_s.strip)
          downloaded << entry
        else
          failed << entry
        end
      end
      [downloaded, failed]
    end

    def index_rows(index_path)
      return [] unless index_path && File.file?(index_path)

      content = File.read(index_path).force_encoding('UTF-8').scrub
      CSV.parse(content, headers: true).map { |row| row.to_h }
    rescue StandardError
      []
    end

    def index_row_matches?(row, entry)
      same = lambda do |a, b|
        a = a.to_s.strip.downcase
        b = b.to_s.strip.downcase
        a.empty? || b.empty? ? false : a == b
      end
      same.call(row['artist'], entry[:artist]) &&
        (same.call(row['album'], entry[:album]) || same.call(row['title'], entry[:title]))
    end

    def organize_staging
      MusicLibrary.organize(source: MusicSearch.music_staging)
    rescue StandardError => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding)) rescue nil
    end

    def build_report(list, downloaded, failed)
      {
        'attempted' => list.size,
        'downloaded' => downloaded.size,
        'failed' => failed.size,
        'downloaded_entries' => downloaded.map { |e| e[:query] },
        'failed_entries' => failed.map { |e| e[:query] },
        'destination' => (MusicSearch.music_destination rescue nil)
      }
    end

    def empty_report(attempted)
      {
        'attempted' => attempted.to_i, 'downloaded' => 0, 'failed' => 0,
        'downloaded_entries' => [], 'failed_entries' => [], 'destination' => nil
      }
    end

    def speak(message)
      app.speaker.speak_up(message, 0) if app.respond_to?(:speaker) && app.speaker
    rescue StandardError
      nil
    end
  end
end

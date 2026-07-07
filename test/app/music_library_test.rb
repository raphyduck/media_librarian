# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/file_utils'

require 'tmpdir'
require_relative '../../app/music_library'

class MusicLibraryTest < Minitest::Test
  def test_audio_files_handles_glob_metacharacters_in_folder_names
    Dir.mktmpdir do |dir|
      album = File.join(dir, 'Artist - Album [FLAC] {2001}')
      FileUtils.mkdir_p(album)
      File.write(File.join(album, '01 - Song.flac'), 'x')
      File.write(File.join(album, 'cover.jpg'), 'x')

      files = MusicLibrary.audio_files(dir)
      assert_equal ['01 - Song.flac'], files.map { |f| File.basename(f) }
    end
  end

  def test_tags_from_library_path_reads_artist_and_album_from_structure
    tags = MusicLibrary.tags_from_library_path('/lib/Daft Punk/Discovery/03 - Digital Love.flac', '/lib')
    assert_equal 'Daft Punk', tags[:artist]
    assert_equal 'Discovery', tags[:album]
  end

  def test_tags_from_library_path_ignores_unknown_placeholders
    tags = MusicLibrary.tags_from_library_path('/lib/Unknown Artist/Unknown Album/song.flac', '/lib')
    assert_empty tags
  end

  def test_tags_from_library_path_requires_artist_album_depth
    assert_empty MusicLibrary.tags_from_library_path('/lib/loose-file.flac', '/lib')
    assert_empty MusicLibrary.tags_from_library_path('/lib/OnlyArtist/song.flac', '/lib')
  end

  def test_prune_empty_dirs_stops_at_library_root
    Dir.mktmpdir do |root|
      leaf = File.join(root, 'Unknown Artist', 'Unknown Album')
      FileUtils.mkdir_p(leaf)
      kept = File.join(root, 'Kept Artist')
      FileUtils.mkdir_p(kept)
      File.write(File.join(kept, 'song.flac'), 'x')

      MusicLibrary.prune_empty_dirs(leaf, root)

      refute File.exist?(File.join(root, 'Unknown Artist'))
      assert File.directory?(root)
      assert File.directory?(kept)
    end
  end

  def test_build_relative_path_from_full_tags
    tags = { artist: 'Daft Punk', album: 'Discovery', title: 'One More Time', track: '1', disc: '' }
    assert_equal 'Daft Punk/Discovery/01 - One More Time.flac',
                 MusicLibrary.build_relative_path(tags, 'flac')
  end

  def test_build_relative_path_multi_disc
    tags = { artist: 'The Wall', album: 'Live', title: 'Intro', track: '3', disc: '2' }
    assert_equal 'The Wall/Live/2-03 - Intro.flac',
                 MusicLibrary.build_relative_path(tags, 'flac')
  end

  def test_build_relative_path_missing_tags_use_defaults_and_fallback_base
    tags = { artist: '', album: '', title: '', track: '', disc: '' }
    assert_equal 'Unknown Artist/Unknown Album/mysteryfile.mp3',
                 MusicLibrary.build_relative_path(tags, 'mp3', 'mysteryfile')
  end

  def test_sanitize_component_strips_illegal_characters
    assert_equal 'AC-DC - Back in Black', MusicLibrary.sanitize_component('AC/DC - Back in Black')
    assert_equal 'Album', MusicLibrary.sanitize_component('  Album?:*  ')
    assert_equal 'Unknown', MusicLibrary.sanitize_component('   ')
    assert_equal 'Trailing', MusicLibrary.sanitize_component('Trailing...')
  end

  def test_parse_from_names_extracts_artist_album_year_from_folder
    tags = MusicLibrary.parse_from_names('01 - One More Time', 'Daft Punk - Discovery (2001) [FLAC]')
    assert_equal 'Daft Punk', tags[:artist]
    assert_equal 'Discovery', tags[:album]
    assert_equal '2001', tags[:year]
    assert_equal '01', tags[:track]
    assert_equal 'One More Time', tags[:title]
  end

  def test_parse_from_names_track_with_dot_separator
    tags = MusicLibrary.parse_from_names('05. Aerodynamic', 'Daft Punk - Discovery')
    assert_equal '05', tags[:track]
    assert_equal 'Aerodynamic', tags[:title]
  end

  def test_parse_from_names_multi_disc_track
    tags = MusicLibrary.parse_from_names('2-04 Something', 'Artist - Album')
    assert_equal '2', tags[:disc]
    assert_equal '04', tags[:track]
    assert_equal 'Something', tags[:title]
  end

  def test_parse_from_names_artist_title_without_track
    tags = MusicLibrary.parse_from_names('Miles Davis - So What', 'Some Folder')
    assert_equal 'So What', tags[:title]
    assert_equal 'Miles Davis', tags[:artist]
  end

  def test_merge_tags_prefers_primary_when_present
    primary = { artist: 'Real Artist', album: '', title: 'Song', track: '', disc: '', year: '' }
    fallback = { artist: 'Guessed', album: 'Guessed Album', title: 'Guessed', track: '2', disc: '', year: '1999' }
    merged = MusicLibrary.merge_tags(primary, fallback)
    assert_equal 'Real Artist', merged[:artist]
    assert_equal 'Guessed Album', merged[:album]
    assert_equal 'Song', merged[:title]
    assert_equal '2', merged[:track]
  end

  def test_name_quality_score_orders_formats
    flac = MusicLibrary.name_quality_score('01 - Song.flac')
    flac_hires = MusicLibrary.name_quality_score('01 - Song 24bit.flac')
    mp3_320 = MusicLibrary.name_quality_score('01 - Song 320.mp3')
    mp3_v0 = MusicLibrary.name_quality_score('01 - Song V0.mp3')
    mp3_plain = MusicLibrary.name_quality_score('01 - Song.mp3')

    assert_operator flac_hires, :>, flac
    assert_operator flac, :>, mp3_320
    assert_operator mp3_320, :>, mp3_v0
    assert_operator mp3_v0, :>, mp3_plain
  end

  def test_name_quality_score_lossless_extension_beats_lossy
    assert_operator MusicLibrary.name_quality_score('track.flac'),
                    :>, MusicLibrary.name_quality_score('track 320.mp3')
  end

  def test_same_track_matches_on_tags_ignoring_case_punctuation_and_naming
    a = { artist: 'ABBA', album: 'Super Trouper', title: 'Super Trouper', year: '1980' }
    b = { artist: 'abba', album: 'super  trouper!', title: 'Super Trouper', year: '1980' }
    assert MusicLibrary.same_track?(a, b)
  end

  def test_same_track_distinguishes_releases_by_album_year
    original = { artist: 'ABBA', album: 'Super Trouper', title: 'Super Trouper', year: '1980' }
    remaster = { artist: 'ABBA', album: 'Super Trouper', title: 'Super Trouper', year: '2011' }
    refute MusicLibrary.same_track?(original, remaster)
  end

  def test_same_track_is_lenient_when_a_year_is_unknown
    tagged = { artist: 'ABBA', album: 'Super Trouper', title: 'Super Trouper', year: '1980' }
    untagged = { artist: 'ABBA', album: 'Super Trouper', title: 'Super Trouper', year: '' }
    assert MusicLibrary.same_track?(tagged, untagged)
  end

  def test_same_track_requires_matching_title_artist_and_album
    base = { artist: 'ABBA', album: 'Super Trouper', title: 'Super Trouper', year: '1980' }
    refute MusicLibrary.same_track?(base, base.merge(title: 'The Winner Takes It All'))
    refute MusicLibrary.same_track?(base, base.merge(album: 'Arrival'))
    refute MusicLibrary.same_track?(base, base.merge(artist: 'Boney M'))
  end

  def test_same_track_requires_a_title_on_both_sides
    titled = { artist: 'ABBA', album: 'Super Trouper', title: 'Super Trouper', year: '1980' }
    untitled = { artist: 'ABBA', album: 'Super Trouper', title: '', year: '1980' }
    refute MusicLibrary.same_track?(titled, untitled)
    refute MusicLibrary.same_track?(untitled, untitled)
  end

  def test_years_compatible_only_separates_two_known_differing_years
    assert MusicLibrary.years_compatible?('1980', '1980')
    assert MusicLibrary.years_compatible?('1980', '')
    assert MusicLibrary.years_compatible?(nil, '1980')
    assert MusicLibrary.years_compatible?('1980-11-03', '1980')
    refute MusicLibrary.years_compatible?('1980', '2011')
  end

  def test_build_relative_path_end_to_end_with_name_parsing
    tags = MusicLibrary.merge_tags(
      { artist: '', album: '', title: '', track: '', disc: '', year: '' },
      MusicLibrary.parse_from_names('03 - Digital Love', 'Daft Punk - Discovery (2001)')
    )
    assert_equal 'Daft Punk/Discovery/03 - Digital Love.flac',
                 MusicLibrary.build_relative_path(tags, 'flac')
  end

  # --- Encoding + destructive-safety (regression for the organize incident) ---

  def test_fs_utf8_retags_ascii8bit_bytes_and_allows_join
    binary = 'Mes courants électriques'.dup.force_encoding('ASCII-8BIT')
    out = MusicLibrary.fs_utf8(binary)
    assert_equal Encoding::UTF_8, out.encoding
    assert out.valid_encoding?
    assert_equal 'Mes courants électriques', out
    # The original crash was File.join('utf8 dir', 'ascii-8bit entry').
    assert_equal 'x/Mes courants électriques', File.join('x', out)
  end

  def test_same_content_true_only_for_identical_files
    Dir.mktmpdir do |d|
      a = File.join(d, 'a'); b = File.join(d, 'b'); c = File.join(d, 'c')
      File.write(a, 'X' * 100); File.write(b, 'X' * 100); File.write(c, 'Y' * 100)
      assert MusicLibrary.same_content?(a, b)
      refute MusicLibrary.same_content?(a, c)
      refute MusicLibrary.same_content?(a, File.join(d, 'missing'))
    end
  end

  def test_organize_file_dry_run_keeps_identical_duplicate
    with_library do |root, base|
      existing = write_file(root, 'Artist/Album/01 - Song.flac', 'AUDIO')
      incoming = write_file(root, 'Incoming/track.flac', 'AUDIO')
      tags = song_tags
      stub_read_tags('01 - Song.flac' => tags, 'track.flac' => tags) do
        MusicLibrary.organize_file(incoming, root, folder_name: 'Incoming', dry_run: true)
      end
      assert File.exist?(incoming), 'dry-run must not remove anything'
      assert File.exist?(existing)
      assert_empty trashed(base)
    end
  end

  def test_organize_file_apply_moves_identical_duplicate_to_trash
    with_library do |root, base|
      existing = write_file(root, 'Artist/Album/01 - Song.flac', 'AUDIO')
      incoming = write_file(root, 'Incoming/track.flac', 'AUDIO')
      tags = song_tags
      stub_read_tags('01 - Song.flac' => tags, 'track.flac' => tags) do
        MusicLibrary.organize_file(incoming, root, folder_name: 'Incoming', dry_run: false)
      end
      refute File.exist?(incoming), 'the identical duplicate is removed from its original spot'
      assert File.exist?(existing), 'the kept copy stays'
      assert_equal 1, trashed(base).size, 'removal is a reversible move to trash'
    end
  end

  # The core of the incident: a same-track file with DIFFERENT content must never
  # be deleted, even when apply is on.
  def test_organize_file_never_deletes_non_identical_sibling
    with_library do |root, base|
      existing = write_file(root, 'Artist/Album/01 - Song.flac', 'ORIGINAL-CONTENT')
      incoming = write_file(root, 'Incoming/track.flac', 'DIFFERENT-HIGHER-QUALITY')
      tags = song_tags
      res = stub_read_tags('01 - Song.flac' => tags, 'track.flac' => tags) do
        MusicLibrary.organize_file(incoming, root, folder_name: 'Incoming', dry_run: false)
      end
      assert File.exist?(existing), 'a non-identical album track is NEVER deleted'
      assert File.exist?(incoming), 'both copies are kept'
      assert_nil res
      assert_empty trashed(base)
    end
  end

  # If the sibling scan fails, an in-place file is left untouched (fail closed).
  def test_organize_file_skips_everything_when_sibling_scan_fails
    with_library do |root, _base|
      incoming = write_file(root, 'Artist/Album/dupe.flac', 'AUDIO')
      write_file(root, 'Artist/Album/01 - Song.flac', 'AUDIO')
      sc = MusicLibrary.singleton_class
      saved = sc.instance_method(:same_track_siblings)
      MusicLibrary.define_singleton_method(:same_track_siblings) { |*| nil }
      begin
        res = stub_read_tags('dupe.flac' => song_tags, '01 - Song.flac' => song_tags) do
          MusicLibrary.organize_file(incoming, root, folder_name: 'Album', dry_run: false)
        end
        assert File.exist?(incoming), 'scan failure -> never delete'
        assert_nil res
      ensure
        sc.send(:define_method, :same_track_siblings, saved)
      end
    end
  end

  def test_organize_file_handles_accented_paths_without_crashing
    with_library do |root, _base|
      f = write_file(root, 'Alizée/Mes courants électriques/01 - À contre-courant.flac', 'AUDIO')
      tags = { artist: 'Alizée', album: 'Mes courants électriques', title: 'À contre-courant',
               track: '1', disc: '', year: '2003' }
      stub_read_tags('01 - À contre-courant.flac' => tags) do
        # Correctly-placed in-place file: no-op, and must not raise on the accents.
        assert_nil MusicLibrary.organize_file(f, root, folder_name: 'Mes courants électriques', dry_run: true)
        assert_kind_of Array, MusicLibrary.same_track_siblings(File.dirname(f), tags)
      end
    end
  end

  def test_organize_defaults_to_dry_run
    with_library do |root, base|
      write_file(root, 'Artist/Album/01 - Song.flac', 'AUDIO')
      dup = write_file(root, 'Dup/01 - Song.flac', 'AUDIO')
      result = stub_read_tags('01 - Song.flac' => song_tags) do
        MusicLibrary.organize(source: root)
      end
      assert_equal true, result['dry_run'], 'organize is dry-run unless --apply'
      assert File.exist?(dup), 'nothing trashed by default'
      assert_empty trashed(base)
    end
  end

  private

  def song_tags
    { artist: 'Artist', album: 'Album', title: 'Song', track: '1', disc: '', year: '2000' }
  end

  def write_file(root, rel, content)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  # Trashed files live under <parent-of-library>/.trash-organize.
  def trashed(base)
    Dir.glob(File.join(base, '.trash-organize', '**', '*')).select { |f| File.file?(f) }
  end

  def with_library
    Dir.mktmpdir do |base|
      root = File.join(base, 'lib')
      FileUtils.mkdir_p(root)
      speaker = Object.new
      def speaker.speak_up(*); end
      def speaker.tell_error(*); end
      app = Object.new
      app.define_singleton_method(:config) { {} }
      app.define_singleton_method(:speaker) { speaker }
      sc = MusicLibrary.singleton_class
      saved = sc.instance_method(:app)
      MusicLibrary.define_singleton_method(:app) { app }
      begin
        yield(root, base)
      ensure
        sc.send(:define_method, :app, saved)
      end
    end
  end

  def stub_read_tags(map)
    sc = MusicLibrary.singleton_class
    saved = sc.instance_method(:read_tags)
    MusicLibrary.define_singleton_method(:read_tags) { |path| map[File.basename(path.to_s)] || {} }
    begin
      yield
    ensure
      sc.send(:define_method, :read_tags, saved)
    end
  end
end

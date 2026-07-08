# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/file_utils'
# FileUtils.mv delegates to MergerfsIO (NAS-safe moves); load it so the
# apply/trash path works when this file is run on its own.
require_relative '../../lib/mergerfs_io'

require 'tmpdir'
require_relative '../../lib/tag_writer'
require_relative '../../app/music_library'
require_relative '../../app/music_search'

# EXTENSIONS_TYPE is defined in init/global.rb, which boots the whole app; when
# these tests run in isolation (single file) that boot has not happened, so
# provide the audio set the organize code needs. Guarded so the full-suite
# definition wins when present.
EXTENSIONS_TYPE = { audio: %w[flac mp3 m4a aac ogg opus wav alac ape wv aiff aif tak tta] }.freeze unless defined?(EXTENSIONS_TYPE)

# Likewise for IRRELEVANT_EXTENSIONS: FileUtils#mv prunes now-empty parent dirs
# via file_remove_parents, which consults this constant. Without it a real move
# still happens but the post-move pruning raises, so move_to_trash swallows the
# error and returns nil. Guarded so the full-suite definition wins when present.
IRRELEVANT_EXTENSIONS = %w[srt nfo txt url] unless defined?(IRRELEVANT_EXTENSIONS)

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
        MusicLibrary.organize(source: root, destination: root)
      end
      assert_equal true, result['dry_run'], 'organize is dry-run unless --apply'
      assert File.exist?(dup), 'nothing trashed by default'
      assert_empty trashed(base)
    end
  end

  # --- Compilations (section 4) ---

  def test_norm_album_base_strips_edition_suffixes
    assert_equal 'Discovery', MusicLibrary.norm_album_base('Discovery (Deluxe Edition)')
    assert_equal 'Abbey Road', MusicLibrary.norm_album_base('Abbey Road - Remastered')
    assert_equal 'Nevermind', MusicLibrary.norm_album_base("Nevermind: 30th Anniversary Edition")
    assert_equal 'Discovery', MusicLibrary.norm_album_base('Discovery')
  end

  def test_build_relative_path_folder_artist_override
    tags = { artist: 'Track Artist', album: 'Ragga Connection', title: 'Song', track: '2', disc: '' }
    assert_equal 'Various Artists/Ragga Connection/02 - Song.flac',
                 MusicLibrary.build_relative_path(tags, 'flac', '', folder_artist: 'Various Artists')
  end

  def test_compilation_dirs_flags_multi_artist_album_folder_only
    Dir.mktmpdir do |dir|
      comp = File.join(dir, 'comp'); FileUtils.mkdir_p(comp)
      a1 = File.join(comp, 'a1.flac'); File.write(a1, 'x')
      a2 = File.join(comp, 'a2.flac'); File.write(a2, 'x')
      solo = File.join(dir, 'solo'); FileUtils.mkdir_p(solo)
      s1 = File.join(solo, 's1.flac'); File.write(s1, 'x')
      s2 = File.join(solo, 's2.flac'); File.write(s2, 'x')

      map = {
        'a1.flac' => { artist: 'Artist A', album: 'Ragga Connection' },
        'a2.flac' => { artist: 'Artist B', album: 'Ragga Connection' },
        's1.flac' => { artist: 'Solo', album: 'Their Album' },
        's2.flac' => { artist: 'Solo', album: 'Their Album' }
      }
      dirs = stub_read_tags(map) { MusicLibrary.compilation_dirs([a1, a2, s1, s2]) }
      assert_equal [comp], dirs, 'only the multi-artist same-album folder is a compilation'
    end
  end

  def test_organize_file_files_compilation_under_various_artists
    with_library do |root, _base|
      # keep the incoming outside the library root (staging) so it is linked in
      staging = Dir.mktmpdir('staging')
      begin
        incoming = File.join(staging, 'track.flac')
        File.write(incoming, 'AUDIO')
        tags = { artist: 'Artist A', album: 'Ragga Connection', title: 'Song', track: '1', disc: '', year: '1998' }
        dest = stub_read_tags('track.flac' => tags) do
          MusicLibrary.organize_file(incoming, root, folder_name: 'Ragga', dry_run: true, compilation: true)
        end
        assert dest, 'the compilation track is filed'
        assert_includes dest, File.join('Various Artists', 'Ragga Connection'),
                        'filed under a single Various Artists/<Album>/ folder'
        assert File.exist?(dest)
      ensure
        FileUtils.remove_entry(staging) if File.directory?(staging)
      end
    end
  end

  # --- Scattered-compilation consolidation ----------------------------------

  def test_scattered_compilation_groups_flags_multi_artist_shared_album
    files = [
      '/lib/Artist A/Ragga Connection/ragga1.flac',
      '/lib/Artist B/Ragga Connection/ragga2.flac',
      '/lib/Artist C/Ragga Connection/ragga3.flac',
      '/lib/Solo/Their Album/solo1.flac',
      '/lib/Solo/Their Album/solo2.flac'
    ]
    map = {
      'ragga1.flac' => { artist: 'Artist A', album: 'Ragga Connection' },
      'ragga2.flac' => { artist: 'Artist B', album: 'Ragga Connection' },
      'ragga3.flac' => { artist: 'Artist C', album: 'Ragga Connection' },
      'solo1.flac' => { artist: 'Solo', album: 'Their Album' },
      'solo2.flac' => { artist: 'Solo', album: 'Their Album' }
    }
    groups = stub_read_tags(map) { MusicLibrary.scattered_compilation_groups(files, 3) }
    assert_equal 1, groups.size, 'only the multi-artist shared album is a scattered compilation'
    g = groups.first
    assert_equal 'Ragga Connection', g['album']
    assert_equal 3, g['artists']
    assert_equal 3, g['dirs']
    assert_equal 3, g['files'].size
  end

  def test_scattered_compilation_groups_merges_edition_variants
    files = [
      '/lib/Artist A/Discovery/a.flac',
      '/lib/Artist B/Discovery (Deluxe Edition)/b.flac',
      '/lib/Artist C/Discovery/c.flac'
    ]
    map = {
      'a.flac' => { artist: 'Artist A', album: 'Discovery' },
      'b.flac' => { artist: 'Artist B', album: 'Discovery (Deluxe Edition)' },
      'c.flac' => { artist: 'Artist C', album: 'Discovery' }
    }
    groups = stub_read_tags(map) { MusicLibrary.scattered_compilation_groups(files, 3) }
    assert_equal 1, groups.size, 'edition variants collapse onto one base album'
    assert_equal 'Discovery', groups.first['album'], 'the plain (most common) title represents the group'
    assert_equal 3, groups.first['files'].size
  end

  def test_scattered_compilation_groups_respects_min_artists_threshold
    files = ['/lib/A/Split/x.flac', '/lib/B/Split/y.flac']
    map = { 'x.flac' => { artist: 'A', album: 'Split' }, 'y.flac' => { artist: 'B', album: 'Split' } }
    assert_empty stub_read_tags(map) { MusicLibrary.scattered_compilation_groups(files, 3) },
                 'two artists do not meet the default threshold of three'
    assert_equal 1, (stub_read_tags(map) { MusicLibrary.scattered_compilation_groups(files, 2) }).size,
                 'lowering the threshold to two flags the split'
  end

  def test_scattered_compilation_groups_skips_generic_titles
    files = ['/lib/A/Greatest Hits/x.flac', '/lib/B/Greatest Hits/y.flac', '/lib/C/Greatest Hits/z.flac']
    map = {
      'x.flac' => { artist: 'A', album: 'Greatest Hits' },
      'y.flac' => { artist: 'B', album: 'Greatest Hits' },
      'z.flac' => { artist: 'C', album: 'Greatest Hits' }
    }
    assert_empty stub_read_tags(map) { MusicLibrary.scattered_compilation_groups(files, 3) },
                 'generic shared titles are never treated as compilations'
  end

  def test_scattered_compilation_groups_skips_already_consolidated_single_folder
    files = [
      '/lib/Various Artists/Ragga Connection/1.flac',
      '/lib/Various Artists/Ragga Connection/2.flac',
      '/lib/Various Artists/Ragga Connection/3.flac'
    ]
    map = {
      '1.flac' => { artist: 'Artist A', album: 'Ragga Connection' },
      '2.flac' => { artist: 'Artist B', album: 'Ragga Connection' },
      '3.flac' => { artist: 'Artist C', album: 'Ragga Connection' }
    }
    assert_empty stub_read_tags(map) { MusicLibrary.scattered_compilation_groups(files, 3) },
                 'a compilation already in one folder needs no consolidation'
  end

  def test_consolidate_compilations_dry_run_changes_nothing
    with_library do |root, _base|
      f1 = write_file(root, File.join('Artist A', 'Ragga Connection', 'ragga1.flac'), 'A')
      f2 = write_file(root, File.join('Artist B', 'Ragga Connection', 'ragga2.flac'), 'B')
      f3 = write_file(root, File.join('Artist C', 'Ragga Connection', 'ragga3.flac'), 'C')
      map = {
        'ragga1.flac' => { artist: 'Artist A', album: 'Ragga Connection', title: 'One', track: '1' },
        'ragga2.flac' => { artist: 'Artist B', album: 'Ragga Connection', title: 'Two', track: '2' },
        'ragga3.flac' => { artist: 'Artist C', album: 'Ragga Connection', title: 'Three', track: '3' }
      }
      res = stub_read_tags(map) { MusicLibrary.consolidate_compilations(destination: root, apply: false) }
      assert_equal true, res['dry_run']
      assert_equal 1, res['compilations']
      assert_equal 3, res['files']
      assert File.exist?(f1) && File.exist?(f2) && File.exist?(f3), 'dry-run relocates nothing'
      refute File.directory?(File.join(root, 'Various Artists')), 'no destination folder is created in dry-run'
    end
  end

  def test_consolidate_compilations_apply_files_under_various_artists
    with_library do |root, _base|
      write_file(root, File.join('Artist A', 'Ragga Connection', 'ragga1.flac'), 'A')
      write_file(root, File.join('Artist B', 'Ragga Connection', 'ragga2.flac'), 'B')
      write_file(root, File.join('Artist C', 'Ragga Connection', 'ragga3.flac'), 'C')
      map = {
        'ragga1.flac' => { artist: 'Artist A', album: 'Ragga Connection', title: 'One', track: '1', disc: '', year: '1998' },
        'ragga2.flac' => { artist: 'Artist B', album: 'Ragga Connection', title: 'Two', track: '2', disc: '', year: '1998' },
        'ragga3.flac' => { artist: 'Artist C', album: 'Ragga Connection', title: 'Three', track: '3', disc: '', year: '1998' }
      }
      res = stub_read_tags(map) { MusicLibrary.consolidate_compilations(destination: root, apply: true) }
      assert_equal false, res['dry_run']
      assert_equal 1, res['compilations']
      assert_equal 3, res['files']
      va = File.join(root, 'Various Artists', 'Ragga Connection')
      assert_equal 3, Dir.glob(File.join(va, '*.flac')).size, 'all three tracks land in one Various Artists/<Album>/ folder'
      refute File.directory?(File.join(root, 'Artist A', 'Ragga Connection')), 'emptied source folders are pruned'
      refute File.directory?(File.join(root, 'Artist B', 'Ragga Connection'))
    end
  end

  # --- Section 8: conditional MusicBrainz ------------------------------------

  def test_tags_complete_requires_artist_album_title_and_track
    assert MusicLibrary.tags_complete?(artist: 'A', album: 'B', title: 'C', track: '1')
    refute MusicLibrary.tags_complete?(artist: 'A', album: 'B', title: 'C', track: ''), 'track number is required'
    refute MusicLibrary.tags_complete?(artist: '', album: 'B', title: 'C', track: '1'), 'artist is required'
    refute MusicLibrary.tags_complete?(artist: 'A', album: '', title: 'C', track: '1'), 'album is required'
    refute MusicLibrary.tags_complete?(artist: 'A', album: 'B', title: '', track: '1'), 'title is required'
  end

  def test_complete_tags_auto_skips_musicbrainz_for_fully_tagged_file
    with_library do
      tags = { artist: 'A', album: 'B', title: 'C', track: '1', disc: '', year: '' }
      with_fake_musicbrainz(artist: 'WRONG') do |calls|
        out = MusicLibrary.complete_tags(tags, nil, mode: 'auto')
        assert_empty calls, 'a fully-tagged file never hits MusicBrainz in auto mode'
        assert_equal 'A', out[:artist], 'existing tags are kept as-is'
      end
    end
  end

  def test_complete_tags_auto_queries_musicbrainz_when_incomplete
    with_library do
      tags = { artist: 'A', album: 'B', title: '', track: '1', disc: '', year: '' }
      with_fake_musicbrainz(title: 'Filled') do |calls|
        out = MusicLibrary.complete_tags(tags, nil, mode: 'auto')
        assert_equal 1, calls.size, 'MusicBrainz is queried once to fill the gap'
        assert_equal 'Filled', out[:title], 'the looked-up value fills the missing field'
      end
    end
  end

  def test_complete_tags_never_skips_musicbrainz_even_when_incomplete
    with_library do
      tags = { artist: 'A', album: 'B', title: '', track: '1', disc: '', year: '' }
      with_fake_musicbrainz(title: 'Filled') do |calls|
        out = MusicLibrary.complete_tags(tags, nil, mode: 'never')
        assert_empty calls, 'never mode issues no MusicBrainz lookup'
        assert_equal '', out[:title].to_s, 'the gap is left as-is'
      end
    end
  end

  def test_complete_tags_always_queries_musicbrainz_even_when_complete
    with_library do
      tags = { artist: 'A', album: 'B', title: 'C', track: '1', disc: '', year: '' }
      with_fake_musicbrainz(year: '1999') do |calls|
        MusicLibrary.complete_tags(tags, nil, mode: 'always')
        assert_equal 1, calls.size, 'always mode queries MusicBrainz regardless of completeness'
      end
    end
  end

  def test_resolve_musicbrainz_mode_prefers_cli_then_config_then_default
    with_library do
      assert_equal 'never', MusicLibrary.resolve_musicbrainz_mode('never'), 'a valid CLI value wins'
      assert_equal 'always', MusicLibrary.resolve_musicbrainz_mode('ALWAYS'), 'value is case-insensitive'
      assert_equal 'auto', MusicLibrary.resolve_musicbrainz_mode('bogus'), 'an invalid value falls back'
      assert_equal 'auto', MusicLibrary.resolve_musicbrainz_mode(nil), 'default is auto when enabled'
    end
  end

  def test_organize_file_threads_musicbrainz_mode_through
    with_library do |root, _base|
      staging = Dir.mktmpdir('staging')
      begin
        incoming = File.join(staging, 'track.flac')
        File.write(incoming, 'AUDIO')
        # deliberately incomplete tags (no track) so auto/always would query MB
        tags = { artist: 'Artist', album: 'Album', title: 'Song', track: '', disc: '', year: '' }
        dest = with_fake_musicbrainz(track: '7') do |calls|
          d = stub_read_tags('track.flac' => tags) do
            MusicLibrary.organize_file(incoming, root, folder_name: 'Album', dry_run: true, musicbrainz_mode: 'never')
          end
          assert_empty calls, 'never mode reaches complete_tags and suppresses the lookup'
          d
        end
        # STAGING GUARD: with lookups suppressed the tags stay incomplete, so
        # the file must NOT be filed (no best-effort 'Unknown Artist' entries)
        # — it remains in staging for a later retry.
        assert_nil dest, 'an incomplete file never leaves staging'
        assert File.exist?(incoming), 'the incomplete file stays in the staging area'
      ensure
        FileUtils.remove_entry(staging) if File.directory?(staging)
      end
    end
  end

  # --- Section 6: supersede_if_better ---------------------------------------

  def test_supersede_if_better_trashes_lossy_when_lossless_present
    with_library do |root, base|
      old = write_file(root, File.join('Artist', 'Album', '01 - Song.mp3'), 'LOSSY')
      write_file(root, File.join('Artist', 'Album', '01 - Song.flac'), 'LOSSLESS')
      with_music_destination(root) do
        res = stub_read_tags('01 - Song.mp3' => song_tags, '01 - Song.flac' => song_tags) do
          MusicLibrary.supersede_if_better(old, dry_run: false)
        end
        assert res, 'a trashed path is returned'
        refute File.exist?(old), 'the superseded lossy file is moved out of the library'
        assert_equal 1, trashed(base).size, 'the lossy file lands in the reversible trash'
      end
    end
  end

  def test_supersede_if_better_dry_run_keeps_lossy_file
    with_library do |root, base|
      old = write_file(root, File.join('Artist', 'Album', '01 - Song.mp3'), 'LOSSY')
      write_file(root, File.join('Artist', 'Album', '01 - Song.flac'), 'LOSSLESS')
      with_music_destination(root) do
        res = stub_read_tags('01 - Song.mp3' => song_tags, '01 - Song.flac' => song_tags) do
          MusicLibrary.supersede_if_better(old, dry_run: true)
        end
        assert_equal :dry_run, res
        assert File.exist?(old), 'dry-run never removes the original'
        assert_empty trashed(base)
      end
    end
  end

  def test_supersede_if_better_noop_without_lossless_sibling
    with_library do |root, base|
      old = write_file(root, File.join('Artist', 'Album', '01 - Song.mp3'), 'LOSSY')
      with_music_destination(root) do
        res = stub_read_tags('01 - Song.mp3' => song_tags) do
          MusicLibrary.supersede_if_better(old, dry_run: false)
        end
        assert_nil res, 'nothing is done when no lossless copy of the track exists'
        assert File.exist?(old)
        assert_empty trashed(base)
      end
    end
  end

  def test_supersede_if_better_never_touches_a_lossless_source
    with_library do |root, base|
      flac = write_file(root, File.join('Artist', 'Album', '01 - Song.flac'), 'LOSSLESS')
      with_music_destination(root) do
        res = stub_read_tags('01 - Song.flac' => song_tags) do
          MusicLibrary.supersede_if_better(flac, dry_run: false)
        end
        assert_nil res, 'an already-lossless file is never superseded'
        assert File.exist?(flac)
        assert_empty trashed(base)
      end
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

  # supersede_if_better resolves the library root via MusicSearch.music_destination,
  # which otherwise reaches for DEFAULT_MUSIC_DESTINATION (from init/global.rb, not
  # loaded here). Pin it to the sandbox root for the duration of the block.
  def with_music_destination(path)
    sc = MusicSearch.singleton_class
    saved = sc.instance_method(:music_destination)
    MusicSearch.define_singleton_method(:music_destination) { path }
    begin
      yield
    ensure
      sc.send(:define_method, :music_destination, saved)
    end
  end

  # Swap MusicLibrary.musicbrainz for a recorder returning `found`, and disable
  # AcoustID, so complete_tags exercises only the MusicBrainz branch. Yields the
  # list of calls made to #complete.
  def with_fake_musicbrainz(found = {})
    calls = []
    fake = Object.new
    fake.define_singleton_method(:complete) { |**kwargs| calls << kwargs; found }
    sc = MusicLibrary.singleton_class
    saved_mb = sc.instance_method(:musicbrainz)
    saved_ac = sc.instance_method(:acoustid_enabled?)
    MusicLibrary.define_singleton_method(:musicbrainz) { fake }
    MusicLibrary.define_singleton_method(:acoustid_enabled?) { false }
    begin
      yield calls
    ensure
      sc.send(:define_method, :musicbrainz, saved_mb)
      sc.send(:define_method, :acoustid_enabled?, saved_ac)
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

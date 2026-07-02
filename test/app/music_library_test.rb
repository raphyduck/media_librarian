# frozen_string_literal: true

require_relative '../test_helper'

require_relative '../../app/music_library'

class MusicLibraryTest < Minitest::Test
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

  def test_build_relative_path_end_to_end_with_name_parsing
    tags = MusicLibrary.merge_tags(
      { artist: '', album: '', title: '', track: '', disc: '', year: '' },
      MusicLibrary.parse_from_names('03 - Digital Love', 'Daft Punk - Discovery (2001)')
    )
    assert_equal 'Daft Punk/Discovery/03 - Digital Love.flac',
                 MusicLibrary.build_relative_path(tags, 'flac')
  end
end

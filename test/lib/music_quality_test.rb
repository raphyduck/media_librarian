# frozen_string_literal: true

require_relative '../test_helper'

require_relative '../../lib/music_quality'

class MusicQualityTest < Minitest::Test
  def test_flac_matches_any_lossless_release
    assert MusicQuality.matches?('Artist - Album (2020) [FLAC]', 'flac')
    assert MusicQuality.matches?('Artist - Album 2020 FLAC 24bit', 'flac')
    refute MusicQuality.matches?('Artist - Album (2020) [MP3 320]', 'flac')
  end

  def test_flac24_requires_hi_res_marker
    assert MusicQuality.matches?('Artist - Album (2020) FLAC 24bit', 'flac24')
    assert MusicQuality.matches?('Artist - Album (2020) FLAC Hi-Res 96kHz', 'flac24')
    refute MusicQuality.matches?('Artist - Album (2020) FLAC', 'flac24')
    refute MusicQuality.matches?('Artist - Album (2020) MP3 320', 'flac24')
  end

  def test_mp3_320_matches_bitrate_and_rejects_flac
    assert MusicQuality.matches?('Artist - Album (2020) [MP3 320]', 'mp3_320')
    assert MusicQuality.matches?('Artist - Album 320kbps', 'mp3_320')
    refute MusicQuality.matches?('Artist - Album (2020) FLAC', 'mp3_320')
    refute MusicQuality.matches?('Artist - Album (2020) MP3 V0', 'mp3_320')
  end

  def test_mp3_v0_matches_and_rejects_flac
    assert MusicQuality.matches?('Artist - Album (2020) [MP3 V0]', 'mp3_v0')
    refute MusicQuality.matches?('Artist - Album (2020) FLAC V0-labelled', 'mp3_v0')
  end

  def test_blank_quality_matches_everything
    assert MusicQuality.matches?('Anything at all', '')
    assert MusicQuality.matches?('Anything at all', nil)
  end

  def test_filter_keeps_only_matching_results
    results = [
      { name: 'Album FLAC', seeders: 3 },
      { name: 'Album MP3 320', seeders: 9 },
      { name: 'Album MP3 V0', seeders: 5 }
    ]
    filtered = MusicQuality.filter(results, 'mp3_320')
    assert_equal ['Album MP3 320'], filtered.map { |r| r[:name] }
  end

  def test_best_picks_highest_seeders_among_matches
    results = [
      { name: 'Album A FLAC', seeders: 3 },
      { name: 'Album B FLAC', seeders: 12 },
      { name: 'Album C MP3 320', seeders: 99 }
    ]
    best = MusicQuality.best(results, 'flac')
    assert_equal 'Album B FLAC', best[:name]
  end

  def test_options_lists_all_four_qualities
    values = MusicQuality.options.map { |o| o['value'] }
    assert_equal %w[flac flac24 mp3_320 mp3_v0], values
    assert MusicQuality.valid?('flac')
    refute MusicQuality.valid?('wav')
  end
end

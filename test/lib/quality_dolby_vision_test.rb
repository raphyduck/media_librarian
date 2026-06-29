# frozen_string_literal: true

require_relative '../test_helper'

require_relative '../../lib/quality'

class QualityDolbyVisionTest < Minitest::Test
  DV_RELEASES = [
    'Movie.2024.2160p.WEB-DL.DV.HDR.x265-GROUP.mkv',
    'Movie.2024.2160p.BluRay.DoVi.x265.mkv',
    'Movie 2024 2160p Dolby Vision x265.mkv',
    'Movie.2024.2160p.Dolby.Vision.Atmos.mkv'
  ].freeze

  NON_DV_RELEASES = [
    'Show.S01E01.1080p.WEB.h264.mkv',
    'The.DVD.Special.Edition.1080p.mkv',
    'Movie.2024.DVDRip.XviD.avi'
  ].freeze

  def test_dolby_vision_releases_are_rejected_when_banned
    DV_RELEASES.each do |name|
      _, accept = Quality.filter_quality(name, { 'ban_dolby_vision' => 1 })
      refute accept, "Expected Dolby Vision release to be rejected: #{name}"
    end
  end

  def test_dolby_vision_releases_are_kept_when_option_disabled
    DV_RELEASES.each do |name|
      _, accept = Quality.filter_quality(name, { 'ban_dolby_vision' => 0 })
      assert accept, "Expected Dolby Vision release to be kept when option is off: #{name}"
    end
  end

  def test_dolby_vision_releases_are_kept_when_option_absent
    DV_RELEASES.each do |name|
      _, accept = Quality.filter_quality(name, {})
      assert accept, "Expected Dolby Vision release to be kept when option is unset: #{name}"
    end
  end

  def test_non_dolby_vision_releases_are_kept_when_banned
    NON_DV_RELEASES.each do |name|
      _, accept = Quality.filter_quality(name, { 'ban_dolby_vision' => 1 })
      assert accept, "Expected non Dolby Vision release to be kept: #{name}"
    end
  end

  def test_ban_accepts_boolean_true
    _, accept = Quality.filter_quality(DV_RELEASES.first, { 'ban_dolby_vision' => true })
    refute accept, 'Expected ban_dolby_vision: true to reject Dolby Vision release'
  end
end

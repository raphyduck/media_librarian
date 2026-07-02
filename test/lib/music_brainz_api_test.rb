# frozen_string_literal: true

require_relative '../test_helper'

require_relative '../../lib/music_brainz_api'

class MusicBrainzApiTest < Minitest::Test
  def setup
    @api = MusicBrainzApi.new
  end

  def test_normalize_recording_extracts_artist_title_album_year
    payload = {
      'recordings' => [
        {
          'title' => 'One More Time',
          'artist-credit' => [{ 'name' => 'Daft Punk', 'joinphrase' => '' }],
          'releases' => [{ 'title' => 'Discovery', 'date' => '2001-03-12' }]
        }
      ]
    }
    tags = @api.normalize_recording(payload)
    assert_equal 'Daft Punk', tags[:artist]
    assert_equal 'One More Time', tags[:title]
    assert_equal 'Discovery', tags[:album]
    assert_equal '2001', tags[:year]
  end

  def test_normalize_recording_empty_payload_returns_empty
    assert_empty @api.normalize_recording({})
    assert_empty @api.normalize_recording({ 'recordings' => [] })
    assert_empty @api.normalize_recording(nil)
  end

  def test_normalize_release_without_track
    payload = {
      'releases' => [
        {
          'title' => 'Discovery',
          'date' => '2001',
          'artist-credit' => [{ 'name' => 'Daft Punk', 'joinphrase' => '' }]
        }
      ]
    }
    tags = @api.normalize_release(payload)
    assert_equal 'Daft Punk', tags[:artist]
    assert_equal 'Discovery', tags[:album]
    assert_equal '2001', tags[:year]
    refute tags.key?(:title)
  end

  def test_artist_credit_name_joins_multiple_artists
    credit = [
      { 'name' => 'Artist A', 'joinphrase' => ' & ' },
      { 'name' => 'Artist B', 'joinphrase' => '' }
    ]
    assert_equal 'Artist A & Artist B', @api.artist_credit_name(credit)
  end

  def test_artist_credit_name_falls_back_to_nested_artist_name
    credit = [{ 'artist' => { 'name' => 'Nested Name' }, 'joinphrase' => '' }]
    assert_equal 'Nested Name', @api.artist_credit_name(credit)
  end

  def test_complete_returns_empty_when_no_usable_input
    assert_empty @api.complete(artist: '', album: '', title: '', track: '')
  end
end

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

  def test_normalize_release_exposes_albumartist
    payload = {
      'releases' => [
        {
          'title' => 'Now 42',
          'date' => '1999',
          'artist-credit' => [{ 'name' => 'Various Artists', 'joinphrase' => '' }]
        }
      ]
    }
    tags = @api.normalize_release(payload)
    assert_equal 'Various Artists', tags[:albumartist], 'release artist-credit becomes albumartist'
    assert_equal 'Various Artists', tags[:artist]
  end

  def test_normalize_recording_albumartist_prefers_release_credit
    payload = {
      'recordings' => [
        {
          'title' => 'Song',
          'artist-credit' => [{ 'name' => 'Some Artist', 'joinphrase' => '' }],
          'releases' => [
            { 'title' => 'A Comp', 'date' => '2005',
              'artist-credit' => [{ 'name' => 'Various Artists', 'joinphrase' => '' }] }
          ]
        }
      ]
    }
    tags = @api.normalize_recording(payload)
    assert_equal 'Various Artists', tags[:albumartist], 'albumartist from release credit'
    assert_equal 'Some Artist', tags[:artist], 'track artist stays the recording artist'
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
  def test_compilation_release_yes_when_va_release_matches
    payload = { 'releases' => [
      { 'title' => 'Ragga Connection',
        'artist-credit' => [{ 'name' => 'Various Artists',
                              'artist' => { 'id' => MusicBrainzApi::VARIOUS_ARTISTS_MBID, 'name' => 'Various Artists' } }] }
    ] }
    @api.stub(:search, payload) do
      assert_equal :yes, @api.compilation_release('Ragga Connection')
    end
  end

  def test_compilation_release_no_when_single_artist_release
    payload = { 'releases' => [
      { 'title' => 'The Best of Boney M.',
        'artist-credit' => [{ 'name' => 'Boney M.', 'artist' => { 'id' => 'abc', 'name' => 'Boney M.' } }] }
    ] }
    @api.stub(:search, payload) do
      assert_equal :no, @api.compilation_release('The Best of Boney M.')
    end
  end

  def test_compilation_release_unknown_when_nothing_found
    @api.stub(:search, { 'releases' => [] }) do
      assert_equal :unknown, @api.compilation_release('Totally Unknown Album')
    end
  end

  def test_compilation_release_matches_va_by_name_without_mbid
    payload = { 'releases' => [
      { 'title' => 'Now Dance', 'artist-credit' => [{ 'name' => 'various artists' }] }
    ] }
    @api.stub(:search, payload) do
      assert_equal :yes, @api.compilation_release('Now Dance')
    end
  end

  def test_compilation_release_fuzzy_fallback_on_dirty_title
    payload = { 'releases' => [
      { 'title' => 'Ragga Connection',
        'artist-credit' => [{ 'name' => 'Various Artists',
                              'artist' => { 'id' => MusicBrainzApi::VARIOUS_ARTISTS_MBID } }] }
    ] }
    @api.stub(:search, payload) do
      # dirty incoming title (extra punctuation) still matches via fuzzy contains
      assert_equal :yes, @api.compilation_release('Ragga Connection!!!')
    end
  end

end

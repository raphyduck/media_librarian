# frozen_string_literal: true

require_relative '../test_helper'

require_relative '../../lib/acoustid_api'

class AcoustidApiTest < Minitest::Test
  def setup
    @api = AcoustidApi.new(api_key: 'test-key')
  end

  def test_normalize_response_extracts_best_scoring_recording
    payload = {
      'status' => 'ok',
      'results' => [
        {
          'score' => 0.55,
          'recordings' => [{ 'id' => 'low', 'title' => 'Low', 'artists' => [{ 'name' => 'Low Artist' }] }]
        },
        {
          'score' => 0.97,
          'recordings' => [
            {
              'id' => 'mbid-1',
              'title' => 'One More Time',
              'artists' => [{ 'name' => 'Daft Punk', 'joinphrase' => '' }],
              'releasegroups' => [{ 'title' => 'Discovery', 'first-release-date' => '2001-03-12' }]
            }
          ]
        }
      ]
    }
    tags = @api.normalize_response(payload)
    assert_equal 'Daft Punk', tags[:artist]
    assert_equal 'One More Time', tags[:title]
    assert_equal 'Discovery', tags[:album]
    assert_equal '2001', tags[:year]
    assert_equal 'mbid-1', tags[:mbid]
  end

  def test_normalize_response_ignores_low_scores
    payload = {
      'status' => 'ok',
      'results' => [
        { 'score' => 0.2, 'recordings' => [{ 'id' => 'x', 'title' => 'T', 'artists' => [{ 'name' => 'A' }] }] }
      ]
    }
    assert_empty @api.normalize_response(payload)
  end

  def test_normalize_response_handles_error_and_empty_payloads
    assert_empty @api.normalize_response({ 'status' => 'error' })
    assert_empty @api.normalize_response({})
    assert_empty @api.normalize_response(nil)
    assert_empty @api.normalize_response({ 'status' => 'ok', 'results' => [] })
  end

  def test_artist_names_joins_with_joinphrases
    artists = [
      { 'name' => 'Artist A', 'joinphrase' => ' feat. ' },
      { 'name' => 'Artist B', 'joinphrase' => '' }
    ]
    assert_equal 'Artist A feat. Artist B', @api.artist_names(artists)
  end

  def test_disabled_without_api_key
    refute AcoustidApi.new(api_key: '').enabled?
    assert @api.enabled?
  end

  def test_lookup_returns_empty_when_disabled
    assert_empty AcoustidApi.new(api_key: '').lookup('/some/file.flac')
  end
end

# frozen_string_literal: true

require_relative '../test_helper'

require_relative '../../lib/acoustid_api'

class AcoustidApiTest < Minitest::Test
  FakeResponse = Struct.new(:code, :body, :headers)

  class FakeHttpClient
    attr_reader :calls

    def initialize(responses)
      @responses = Array(responses)
      @calls = []
    end

    def get(url, options = {})
      @calls << [url, options]
      @responses.length > 1 ? @responses.shift : @responses.first
    end
  end

  def setup
    AcoustidApi.last_request_at = nil
    @api = AcoustidApi.new(api_key: 'test-key')
  end

  def ok_payload(score, with_recording: true)
    result = { 'score' => score }
    if with_recording
      result['recordings'] = [
        {
          'id' => 'mbid-1',
          'title' => 'One More Time',
          'artists' => [{ 'name' => 'Daft Punk', 'joinphrase' => '' }],
          'releasegroups' => [{ 'title' => 'Discovery', 'first-release-date' => '2001-03-12' }]
        }
      ]
    end
    { 'status' => 'ok', 'results' => [result] }
  end

  def api_for(payloads, min_score: nil)
    payloads = [payloads] unless payloads.is_a?(Array)
    responses = payloads.map { |payload| FakeResponse.new(200, payload.to_json, {}) }
    AcoustidApi.new(api_key: 'test-key', http_client: FakeHttpClient.new(responses), min_score: min_score)
  end

  def with_fingerprint(api, &block)
    api.stub(:fingerprint, { :duration => 120, :fingerprint => 'abc' }, &block)
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

  def test_normalize_response_rejects_scores_under_default_threshold
    payload = ok_payload(0.7)
    assert_empty @api.normalize_response(payload), 'a 0.7 match is below the 0.85 default floor'
  end

  def test_min_score_is_configurable
    api = AcoustidApi.new(api_key: 'k', min_score: 0.5)
    assert_equal 0.5, api.min_score
    assert_equal 'Daft Punk', api.normalize_response(ok_payload(0.7))[:artist]
    assert_equal AcoustidApi::MIN_SCORE, AcoustidApi.new(api_key: 'k').min_score
    assert_equal AcoustidApi::MIN_SCORE, AcoustidApi.new(api_key: 'k', min_score: '').min_score
  end

  def test_identify_reports_identified_with_score
    api = api_for(ok_payload(0.93))
    with_fingerprint(api) do
      result = api.identify('/x.flac')
      assert_equal :identified, result[:status]
      assert_in_delta 0.93, result[:score]
      assert_equal 'Daft Punk', result[:tags][:artist]
      assert_equal 'One More Time', result[:tags][:title]
    end
  end

  def test_identify_flags_low_confidence_matches
    api = api_for(ok_payload(0.6))
    with_fingerprint(api) do
      result = api.identify('/x.flac')
      assert_equal :low_confidence, result[:status]
      assert_in_delta 0.6, result[:score]
      assert_nil result[:tags], 'an untrusted match never exposes tags'
    end
  end

  def test_identify_reports_no_match_when_service_returns_nothing
    api = api_for({ 'status' => 'ok', 'results' => [] })
    with_fingerprint(api) do
      assert_equal :no_match, api.identify('/x.flac')[:status]
    end
  end

  def test_identify_reports_no_fingerprint_when_fpcalc_fails
    api = api_for(ok_payload(0.93))
    api.stub(:fingerprint, nil) do
      assert_equal :no_fingerprint, api.identify('/x.flac')[:status]
    end
  end

  def test_identify_reports_disabled_without_key
    assert_equal :disabled, AcoustidApi.new(api_key: '').identify('/x.flac')[:status]
  end

  def test_fetch_remote_throttles_successive_requests
    api = api_for(ok_payload(0.9))
    slept = []
    api.stub(:sleep, ->(s) { slept << s }) do
      api.send(:fetch_remote, 'fp-1', 100)
      api.send(:fetch_remote, 'fp-2', 100)
    end
    refute_empty slept, 'the second immediate request must wait for the rate-limit interval'
    assert slept.all? { |s| s > 0 && s <= AcoustidApi::MIN_INTERVAL }
  end

  def test_fetch_remote_retries_on_429_with_retry_after
    responses = [
      FakeResponse.new(429, '', { 'retry-after' => '2' }),
      FakeResponse.new(200, ok_payload(0.9).to_json, {})
    ]
    client = FakeHttpClient.new(responses)
    api = AcoustidApi.new(api_key: 'k', http_client: client)
    slept = []
    payload = api.stub(:sleep, ->(s) { slept << s }) do
      api.send(:fetch_remote, 'fp', 100)
    end
    assert_equal 'ok', payload['status']
    assert_equal 2, client.calls.size, 'the 429 is retried once'
    assert_includes slept, 2, 'the Retry-After header is honoured'
  end
end

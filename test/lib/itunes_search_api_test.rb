# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/itunes_search_api'

class ItunesSearchApiTest < Minitest::Test
  def setup
    @api = ItunesSearchApi.new(http_client: nil)
  end

  def test_normalize_song_extracts_tags
    payload = { 'results' => [{ 'artistName' => 'James Horner', 'collectionName' => 'Titanic OST',
                                'trackName' => 'Hymn to the Sea', 'trackNumber' => 14,
                                'discNumber' => 1, 'releaseDate' => '1997-11-18T08:00:00Z' }] }
    tags = @api.normalize_song(payload)
    assert_equal 'James Horner', tags[:artist]
    assert_equal 'Titanic OST', tags[:album]
    assert_equal 'Hymn to the Sea', tags[:title]
    assert_equal '14', tags[:track]
    assert_equal '1997', tags[:year]
  end

  def test_normalize_song_empty_payload
    assert_equal({}, @api.normalize_song(nil))
    assert_equal({}, @api.normalize_song({ 'results' => [] }))
  end

  def test_normalize_album_extracts_tags
    payload = { 'results' => [{ 'artistName' => 'Green Day', 'collectionName' => 'American Idiot',
                                'releaseDate' => '2004-09-21' }] }
    tags = @api.normalize_album(payload)
    assert_equal 'Green Day', tags[:artist]
    assert_equal 'American Idiot', tags[:album]
    assert_equal '2004', tags[:year]
    refute tags.key?(:title), 'album search yields no title'
  end

  def test_complete_without_title_or_album_returns_empty
    assert_equal({}, @api.complete(artist: 'Someone'))
  end
end

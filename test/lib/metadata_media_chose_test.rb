# frozen_string_literal: true

require_relative '../test_helper'

require_relative '../../lib/utils'
require_relative '../../lib/string_utils'
require_relative '../../lib/metadata'

{
  SPACE_SUBSTITUTE: '\\. _\\-',
  VALID_VIDEO_EXT: '(.*)\\.(mkv)$',
  BASIC_EP_MATCH: '((s|S)\\d{1,3}[exEX]\\d{1,4})'
}.each do |const, value|
  Object.const_set(const, value) unless Object.const_defined?(const)
end

class MetadataMediaChoseTest < Minitest::Test
  KEYS = { 'name' => 'name', 'titles' => 'alt_titles', 'url' => 'url', 'year' => 'year' }.freeze

  def candidate(name, year, alt_titles: nil, url: '')
    { 'name' => name, 'year' => year, 'alt_titles' => alt_titles, 'url' => url }
  end

  # "Intruders (2016)": the Norwegian "Vill mark" carries "Intruders" among its
  # translated titles and the same release year as the American "Intruders".
  # First-match-wins used to let whichever came out of the (unstable) year sort
  # first take the title; the provider's popularity ranking must decide.
  def test_same_year_homonyms_resolve_to_the_provider_ranked_first
    items = [
      candidate('Intruders (2016)', 2016),
      candidate('Vill mark (2016)', 2016, alt_titles: ['Vill mark (2016)', 'Intruders (2016)'])
    ]

    title, item = Metadata.media_chose('Intruders (2016)', items, KEYS, 'movies', 1)

    assert_equal 'Intruders (2016)', title
    refute_nil item
    assert_nil item['alt_titles'], 'the provider-ranked-first candidate must win, not the alt-titled homonym'
  end

  # "Influencer (2022)": a fuzzy alt-title match with the exact year used to
  # beat the movie actually carrying the searched title.
  def test_exact_title_beats_fuzzy_match_regardless_of_candidate_order
    items = [
      candidate('El Gran Influencer (2022)', 2022),
      candidate('Influencer (2022)', 2022)
    ]

    title, item = Metadata.media_chose('Influencer (2022)', items, KEYS, 'movies', 1)

    assert_equal 'Influencer (2022)', title
    assert_equal 'Influencer (2022)', item['name']
  end

  def test_exact_title_beats_a_closer_year_fuzzy_match
    items = [
      candidate('Influencer The Movie (2022)', 2022),
      candidate('Influencer (2023)', 2023)
    ]

    title, item = Metadata.media_chose('Influencer (2022)', items, KEYS, 'movies', 1)

    assert_equal 'Influencer (2023)', item['name'], 'an exact title one year off must beat a fuzzy same-year match'
    assert_equal 'Influencer (2023)', title
  end

  def test_returns_no_item_rather_than_a_wrong_year_candidate
    items = [candidate('Influencer (2010)', 2010)]

    title, item = Metadata.media_chose('Influencer (2022)', items, KEYS, 'movies', 1)

    assert_nil item, 'a candidate outside the year tolerance must not be picked'
    assert_equal 'Influencer (2022)', title
  end

  def test_exact_match_on_an_alternative_title_counts_as_exact
    items = [
      candidate('LInfluenceuse The Series (2022)', 2022),
      candidate('L Influenceuse (2022)', 2022, alt_titles: ['L Influenceuse (2022)', 'Influencer (2022)'])
    ]

    title, item = Metadata.media_chose('Influencer (2022)', items, KEYS, 'movies', 1)

    refute_nil item
    assert_equal 'Influencer (2022)', title
  end
end

class MetadataMediaLookupYearTest < Minitest::Test
  def setup
    unless defined?(Cache)
      Object.const_set(:Cache, Class.new)
    end
    Cache.define_singleton_method(:cache_get) { |*_| nil } unless Cache.respond_to?(:cache_get)
    Cache.define_singleton_method(:cache_add) { |*_| nil } unless Cache.respond_to?(:cache_add)
  end

  class RecordingProvider
    attr_reader :calls

    def initialize
      @calls = []
    end

    def search_with_year(title, year = nil)
      @calls << [title, year]
      []
    end

    def search_plain(title)
      @calls << [title]
      []
    end
  end

  def test_media_lookup_passes_the_release_year_to_providers_accepting_it
    provider = RecordingProvider.new
    fetcher = ->(_ids) { ['', nil] }

    Metadata.media_lookup('movies', 'Influencer (2022)', 'movie_lookup', MetadataMediaChoseTest::KEYS,
                          fetcher, [[provider, :search_with_year]], 1, '')

    assert_equal [['Influencer', 2022]], provider.calls
  end

  def test_media_lookup_keeps_single_argument_providers_untouched
    provider = RecordingProvider.new
    fetcher = ->(_ids) { ['', nil] }

    Metadata.media_lookup('movies', 'Influencer (2022)', 'movie_lookup', MetadataMediaChoseTest::KEYS,
                          fetcher, [[provider, :search_plain]], 1, '')

    assert_equal [['Influencer']], provider.calls
  end
end

# frozen_string_literal: true

require_relative '../test_helper'

require_relative '../../lib/utils'
require_relative '../../lib/metadata'

{
  SPACE_SUBSTITUTE: '\\. _\\-',
  VALID_VIDEO_EXT: '(.*)\\.(mkv)$',
  BASIC_EP_MATCH: '((s|S)\\d{1,3}[exEX]\\d{1,4})'
}.each do |const, value|
  Object.const_set(const, value) unless Object.const_defined?(const)
end

class MetadataMatchTitlesTest < Minitest::Test
  def test_ignores_optional_numeric_tokens_when_titles_match
    title = '20th Century Boys: Beginning of the End (2008)'
    target = '20th Century Boys 1 Beginning of the End (2008)'

    assert Metadata.match_titles(title, target, 2008, 2008, 'movies')
  end

  def test_matches_when_provider_title_is_suffix_of_search_title
    # TMDB returns "Allegiant" but watchlist has "The Divergent Series: Allegiant"
    assert Metadata.match_titles(
      'Allegiant (2016)', 'The Divergent Series: Allegiant (2016)',
      2016, 2016, 'movies'
    )
  end

  def test_matches_when_provider_title_is_suffix_with_franchise_prefix
    # TMDB returns "Dark Phoenix" but watchlist has "X-Men: Dark Phoenix"
    assert Metadata.match_titles(
      'Dark Phoenix (2019)', 'X-Men: Dark Phoenix (2019)',
      2019, 2019, 'movies'
    )
  end

  def test_matches_when_search_title_is_prefix_of_provider_title
    # Watchlist has "Borat" but TMDB returns the full title
    assert Metadata.match_titles(
      'Borat: Cultural Learnings of America for Make Benefit Glorious Nation of Kazakhstan (2006)',
      'Borat (2006)',
      2006, 2006, 'movies'
    )
  end

  def test_matches_superscript_numbers_to_regular_numbers
    # Watchlist has "Cube²: Hypercube" but TMDB returns "Cube 2: Hypercube"
    assert Metadata.match_titles(
      'Cube 2: Hypercube (2002)', "Cube\u00B2: Hypercube (2003)",
      2002, 2003, 'movies'
    )
  end

  def test_rejects_different_movies_with_similar_prefix
    # "Borat" should not match "Borat Subsequent Moviefilm" when years differ
    refute Metadata.match_titles(
      'Borat Subsequent Moviefilm (2020)', 'Borat (2006)',
      2020, 2006, 'movies'
    )
  end

  def test_rejects_completely_different_titles_same_year
    # Unrelated movies with the same year should not match
    refute Metadata.match_titles(
      'Avatar (2009)', 'Inception (2009)',
      2009, 2009, 'movies'
    )
  end

  def test_reverse_regex_matches_exact_title_in_opposite_direction
    # The regex of the shorter title matches the longer title
    assert Metadata.match_titles(
      'Alien 3 (1992)', "Alien\u00B3 (1992)",
      1992, 1992, 'movies'
    )
  end

  def test_normalize_special_chars
    assert_equal '2', Metadata.normalize_special_chars("\u00B2")
    assert_equal '3', Metadata.normalize_special_chars("\u00B3")
    assert_equal '1', Metadata.normalize_special_chars("\u00B9")
    assert_equal 'Alien 3', Metadata.normalize_special_chars("Alien\u00B3")
    assert_equal 'Cube 2', Metadata.normalize_special_chars("Cube\u00B2")
  end

  def test_title_contained_suffix
    assert Metadata.title_contained?('allegiant', 'divergent series allegiant')
    assert Metadata.title_contained?('dark phoenix', 'x men dark phoenix')
  end

  def test_title_contained_prefix
    assert Metadata.title_contained?('borat', 'borat cultural learnings of america')
  end

  def test_title_contained_rejects_unrelated
    refute Metadata.title_contained?('avatar', 'inception')
  end
end

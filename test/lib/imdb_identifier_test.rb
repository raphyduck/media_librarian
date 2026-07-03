# frozen_string_literal: true

require_relative '../test_helper'

require_relative '../../lib/media_librarian/imdb_identifier'

class ImdbIdentifierTest < Minitest::Test
  M = MediaLibrarian::ImdbIdentifier

  def test_normalize_coerces_common_forms_to_tt_digits
    assert_equal 'tt1234567', M.normalize_identifier('tt1234567')
    assert_equal 'tt1234567', M.normalize_identifier('1234567')
    assert_equal 'tt1234567', M.normalize_identifier('imdb1234567')
    assert_equal 'tt1234567', M.normalize_identifier('  tt1234567 ')
  end

  def test_normalize_returns_blank_for_empty_and_token_for_non_numeric
    assert_equal '', M.normalize_identifier('   ')
    assert_equal '', M.normalize_identifier(nil)
    assert_equal 'tt123abc', M.normalize_identifier('tt123abc') # not all digits -> unchanged
  end

  def test_identifier_accepts_only_canonical_tt_digits
    assert M.imdb_identifier?('tt1234567')
    refute M.imdb_identifier?('1234567')
    refute M.imdb_identifier?('555')
    refute M.imdb_identifier?('')
  end

  def test_identifier_is_anchored_rejecting_trailing_junk
    # Regression guard: the calendar service previously used an unanchored
    # regex and would have accepted these malformed ids.
    refute M.imdb_identifier?('tt123abc')
    refute M.imdb_identifier?('tt1234567x')
    refute M.imdb_identifier?('tt1234567 (2020)')
  end
end

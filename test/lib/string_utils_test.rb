# frozen_string_literal: true

require_relative '../test_helper'

require 'titleize'

SPACE_SUBSTITUTE = '\\.
 _\\-' unless defined?(SPACE_SUBSTITUTE)

module Metadata
  def self.identify_release_year(str)
    (str[/\((\d{4})\)$/, 1] || 0).to_i
  end
end unless defined?(Metadata)

require_relative '../../lib/string_utils'

class StringUtilsTest < Minitest::Test
  def test_accents_clear_transliterates_nested_structures
    assert_equal 'AaEeIiOoUu', StringUtils.accents_clear('ÀaÊeÎiÔoÛu')
    assert_equal ['Cafe'], StringUtils.accents_clear(['Café'])
    assert_equal({ 'Cafe' => 'Resume' }, StringUtils.accents_clear({ 'Café' => 'Résumé' }))
  end

  def test_fix_encoding_removes_invalid_sequences
    invalid = +"caf\xE9"
    invalid.force_encoding('ISO-8859-1').force_encoding('UTF-8')

    fixed = StringUtils.fix_encoding(invalid)

    assert_equal 'caf', fixed
    assert fixed.valid_encoding?
  end

  def test_clean_search_normalizes_titles
    assert_equal 'Office', StringUtils.clean_search('The Office (US)')
    assert_equal 'Planete Terre', StringUtils.clean_search('Planète Terre')
  end

  def test_commatize_adds_separator_only_when_needed
    assert_equal '', StringUtils.commatize('')
    assert_equal ', ', StringUtils.commatize('value')
  end

  def test_gsub_accepts_array_of_patterns
    assert_equal 'x x', StringUtils.gsub('Hello World', ['hello', 'world'], 'x')
  end

  def test_intersection_returns_common_prefix
    assert_equal 'lock_time', StringUtils.intersection('lock_timer', 'lock_time_record')
    assert_equal '', StringUtils.intersection('alpha', 'beta')
  end

  def test_pluralize_adds_suffix_when_quantity_greater_than_one
    assert_equal '', StringUtils.pluralize(1)
    assert_equal 's', StringUtils.pluralize(2)
  end

  def test_regexify_builds_pattern_for_compound_titles
    pattern = StringUtils.regexify('Les Misérables')

    assert_includes pattern, 'Misérab'
    assert_includes pattern, '(le)?'
  end

  def test_regularise_media_filename_applies_requested_formatting
    result = StringUtils.regularise_media_filename('My Movie: Extra', 'titleize|nospace')
    assert_equal 'My.Movie.Extra', result

    downcased = StringUtils.regularise_media_filename('Another Movie', 'downcase')
    assert_equal 'another movie', downcased
  end

  def test_title_match_string_includes_year_range_and_regex_suffix
    pattern = StringUtils.title_match_string('Example (2020)')

    assert_includes pattern, '2019|2020|2021'
    assert pattern.end_with?('.{0,7}$')
  end
end


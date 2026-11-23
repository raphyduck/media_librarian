# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/languages'
require_relative '../../init/languages_translation' unless defined?(LANG_ADJUST)

class LanguagesTest < Minitest::Test
  def test_norwegian_iso639_2_codes_map_to_no
    %w[nor nob nno nb nn no norwegian NOR].each do |code|
      assert_equal 'no', Languages.get_code(code), "code #{code}"
    end
  end

  def test_common_iso639_2_codes_map_to_iso639_1
    {
      'swe' => 'sv', 'dan' => 'da', 'fin' => 'fi', 'pol' => 'pl',
      'ice' => 'is', 'isl' => 'is', 'cze' => 'cs', 'ces' => 'cs',
      'gre' => 'el', 'heb' => 'he', 'tur' => 'tr', 'hun' => 'hu'
    }.each do |code, expected|
      assert_equal expected, Languages.get_code(code), "code #{code}"
    end
  end

  def test_existing_codes_are_unchanged
    { 'fr' => 'fr', 'fre' => 'fr', 'fra' => 'fr', 'french' => 'fr', 'vf' => 'fr',
      'truefrench' => 'fr', 'en' => 'en', 'eng' => 'en', 'english' => 'en',
      'ger' => 'de', 'deu' => 'de', 'kor' => 'ko' }.each do |code, expected|
      assert_equal expected, Languages.get_code(code), "code #{code}"
    end
  end

  def test_empty_and_undetermined_codes_return_nil
    [nil, '', 'und', 'mul', 'zxx'].each do |code|
      assert_nil Languages.get_code(code), "code #{code.inspect}"
    end
  end

  def test_iso639_2_table_values_are_language_keys_and_round_trip
    Languages::ISO_639_2.each do |code3, code2|
      assert LANG_ADJUST.key?(code2.to_sym), "#{code3} -> #{code2} is not a LANG_ADJUST key"
      assert_equal code2, Languages.get_code(code3), "round trip #{code3}"
    end
  end

  def test_sort_languages_does_not_pick_up_three_letter_codes_from_table
    sorted = Languages.sort_languages('fr en')
    %w[nor dan fin ice].each do |code|
      refute_includes sorted, code
    end
  end
end

# frozen_string_literal: true

require_relative '../test_helper'

require 'titleize'

SPACE_SUBSTITUTE = '\\.
 _\\-' unless defined?(SPACE_SUBSTITUTE)

Object.send(:remove_const, :TimeUtils) if defined?(TimeUtils) && !TimeUtils.is_a?(Class)

require_relative '../../lib/string_utils'
require_relative '../../lib/time_utils'

class TimeUtilsTest < Minitest::Test
  def test_seconds_in_words_handles_mixed_units
    assert_equal '1 hour, 1 minute, 1 second', TimeUtils.seconds_in_words(3661)
  end

  def test_seconds_in_words_formats_fractional_seconds
    assert_equal '0.5 second', TimeUtils.seconds_in_words(0.5)
  end

  def test_seconds_in_words_returns_empty_string_for_zero
    assert_equal '', TimeUtils.seconds_in_words(0)
  end
end


# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../support/stubs', __dir__))

require 'bigdecimal'
require 'date'
require 'minitest/autorun'
require_relative '../../lib/cache'

class CacheObjectPackTest < Minitest::Test
  class WithoutDup
    undef_method :dup

    def initialize(value)
      @value = value
    end
  end

  def test_pack_object_without_dup
    result = Cache.object_pack(WithoutDup.new('value'))
    assert_equal('CacheObjectPackTest::WithoutDup', result.first)
    assert_equal(['String', 'value'], result.last['value'])
  end

  def test_pack_frozen_object_without_dup
    result = Cache.object_pack(WithoutDup.new('value').freeze)
    assert_equal('CacheObjectPackTest::WithoutDup', result.first)
  end
end

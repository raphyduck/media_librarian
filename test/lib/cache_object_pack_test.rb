# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../support/stubs', __dir__))

require 'bigdecimal'
require 'date'
require 'minitest/autorun'

cache_stub = Object.const_get(:Cache) if Object.const_defined?(:Cache)
Object.send(:remove_const, :Cache) if Object.const_defined?(:Cache)
load File.expand_path('../../lib/cache.rb', __dir__)
RealCache = Cache
Object.send(:remove_const, :Cache)
Object.const_set(:Cache, cache_stub) if cache_stub


class CacheObjectPackTest < Minitest::Test
  class WithoutDup
    undef_method :dup

    def initialize(value)
      @value = value
    end
  end

  def test_pack_object_without_dup
    result = RealCache.object_pack(WithoutDup.new('value'))
    assert_equal('CacheObjectPackTest::WithoutDup', result.first)
    assert_equal(['String', 'value'], result.last['value'])
  end

  def test_pack_frozen_object_without_dup
    result = RealCache.object_pack(WithoutDup.new('value').freeze)
    assert_equal('CacheObjectPackTest::WithoutDup', result.first)
  end

  def test_pack_method_objects
    result = RealCache.object_pack(method(:test_pack_method_objects))
    assert_equal(['String', 'Illegal object type'], result)
  end
end

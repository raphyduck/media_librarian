# frozen_string_literal: true

require_relative '../test_helper'

# Provide minimal stubs for dependencies that DataUtils relies on.
unless defined?(Vash)
  class Vash < Hash; end
end

Cache ||= Module.new

Cache.define_singleton_method(:object_pack) do |value, *_args|
  value
end unless Cache.respond_to?(:object_pack)

require_relative '../../lib/data_utils'

class DataUtilsTest < Minitest::Test
  def test_dump_variable_limits_depth_within_hash
    value = { foo: { bar: 'baz', nested: [1, 2] } }

    output = DataUtils.dump_variable(value, 1)

    assert_includes output, ':foo=>'
    assert_includes output, '<2 element(s)>'
  end

  def test_dump_variable_formats_arrays_and_hashes
    value = { foo: ['bar', 2], flag: nil }

    output = DataUtils.dump_variable(value, 3)

    assert_includes output, '['
    assert_includes output, "'bar'"
    assert_includes output, '2'
    assert_includes output, 'nil'
  end

  def test_dump_variable_respects_maximum_key_threshold
    value = { a: 1, b: 2, c: 3 }

    output = DataUtils.dump_variable(value, 2, 0, 1, 2)

    assert_includes output, ':a=>'
    assert_includes output, ':b=>'
    refute_includes output, ':c=>'
  end

  def test_format_string_handles_various_inputs
    assert_equal 'nil', DataUtils.format_string(nil)
    assert_equal "'sample'", DataUtils.format_string('sample')
    assert_equal ['1', "'two'"], DataUtils.format_string([1, 'two'])

    hash_input = { a: 1, b: 'two' }
    result = DataUtils.format_string(hash_input)

    assert_equal %i[a b], result
    assert_equal({ a: '1', b: "'two'" }, hash_input)
  end
end

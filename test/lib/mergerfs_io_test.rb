# frozen_string_literal: true

require_relative '../test_helper'
require 'fiddle'
require_relative '../../lib/mergerfs_io'

class MergerfsIoTest < Minitest::Test
  def teardown
    MergerfsIo.instance_variable_set(:@getxattr, nil)
  end

  def test_xattr_value_returns_utf8_encoded_string
    utf8_path = "/mnt/data/Movies/Alien\u00B3 (1992)/file.mkv"
    stub_getxattr_with(utf8_path)

    Dir.mktmpdir do |dir|
      result = MergerfsIo.xattr_value(dir, 'user.mergerfs.fullpath')
      assert_equal Encoding::UTF_8, result.encoding,
                   "xattr_value should return UTF-8 encoded strings, got #{result.encoding}"
      assert result.valid_encoding?, "returned string should be valid UTF-8"
      assert_equal utf8_path, result
    end
  end

  def test_xattr_value_returns_nil_for_nonexistent_path
    result = MergerfsIo.xattr_value('/nonexistent/path/that/does/not/exist', 'user.mergerfs.fullpath')
    assert_nil result
  end

  def test_xattr_value_utf8_result_concatenates_with_utf8_strings
    # This reproduces the actual failure: xattr returns a path with non-ASCII chars
    # and it gets interpolated into a UTF-8 string in transfer_with_fallback
    utf8_path = "/mnt/data/Movies/Alien\u00B3 (1992)/file.mkv"
    stub_getxattr_with(utf8_path)

    Dir.mktmpdir do |dir|
      result = MergerfsIo.xattr_value(dir, 'user.mergerfs.fullpath')
      utf8_source = "Alien\u00B3 (1992)"
      # This would raise Encoding::CompatibilityError without the fix
      combined = "source=#{utf8_source} resolved=#{result}"
      assert_includes combined, "Alien\u00B3"
    end
  end

  private

  def stub_getxattr_with(utf8_path)
    raw_bytes = utf8_path.dup.force_encoding(Encoding::ASCII_8BIT)

    fake_getxattr = lambda do |_path_arg, _name_arg, buf_arg, _size_arg|
      if buf_arg.nil? || buf_arg.null?
        raw_bytes.bytesize
      else
        raw_bytes.bytes.each_with_index { |b, i| buf_arg[i] = b }
        raw_bytes.bytesize
      end
    end

    MergerfsIo.instance_variable_set(:@getxattr, fake_getxattr)
  end
end

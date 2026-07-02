# frozen_string_literal: true

require_relative '../test_helper'

require 'tmpdir'
require_relative '../../lib/json_disk_cache'

class JsonDiskCacheTest < Minitest::Test
  def test_fetch_computes_then_serves_from_cache
    Dir.mktmpdir do |dir|
      cache = JsonDiskCache.new(dir: dir)
      calls = 0
      first = cache.fetch('key') { calls += 1; { 'a' => 1 } }
      second = cache.fetch('key') { calls += 1; { 'a' => 2 } }

      assert_equal({ 'a' => 1 }, first)
      assert_equal({ 'a' => 1 }, second)
      assert_equal 1, calls
    end
  end

  def test_fetch_caches_negative_results
    Dir.mktmpdir do |dir|
      cache = JsonDiskCache.new(dir: dir)
      calls = 0
      cache.fetch('miss') { calls += 1; {} }
      cache.fetch('miss') { calls += 1; {} }
      assert_equal 1, calls
    end
  end

  def test_fetch_does_not_cache_when_block_raises
    Dir.mktmpdir do |dir|
      cache = JsonDiskCache.new(dir: dir)
      assert_raises(RuntimeError) { cache.fetch('boom') { raise 'network down' } }
      assert_nil cache.get('boom')

      value = cache.fetch('boom') { { 'ok' => true } }
      assert_equal({ 'ok' => true }, value)
    end
  end

  def test_expired_entries_are_recomputed
    Dir.mktmpdir do |dir|
      cache = JsonDiskCache.new(dir: dir, ttl_days: 1)
      cache.set('k', { 'v' => 1 })
      # Age the stored file well beyond the TTL.
      path = Dir.glob(File.join(dir, '**', '*.json')).first
      refute_nil path
      old = Time.now - (3 * 86_400)
      File.utime(old, old, path)

      calls = 0
      value = cache.fetch('k') { calls += 1; { 'v' => 2 } }
      assert_equal({ 'v' => 2 }, value)
      assert_equal 1, calls
    end
  end
end

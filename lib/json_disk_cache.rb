# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'

# A small TTL-based JSON file cache used to persist external metadata lookups
# (MusicBrainz, AcoustID) across runs so the same query is not repeated.
#
# Entries are stored one JSON file per key under +dir+ (sharded by key prefix).
# Successful results — including "no match" responses — are cached; the block
# passed to #fetch is only re-run on a cache miss or once an entry is older than
# +ttl_days+. Exceptions raised by the block are never cached.
class JsonDiskCache
  DEFAULT_TTL_DAYS = 180

  def initialize(dir:, ttl_days: DEFAULT_TTL_DAYS, speaker: nil)
    @dir = dir.to_s
    @ttl_days = ttl_days.to_i
    @ttl_days = DEFAULT_TTL_DAYS if @ttl_days <= 0
    @speaker = speaker
  end

  # Return the cached value for +key+, or compute it via the block, store it and
  # return it. A cached value may legitimately be nil/{}/[] (negative caching).
  def fetch(key)
    found, value = read(key)
    return value if found

    value = yield
    write(key, value)
    value
  end

  def get(key)
    read(key).last
  end

  def set(key, value)
    write(key, value)
    value
  end

  private

  def read(key)
    path = path_for(key)
    return [false, nil] unless File.file?(path)

    if expired?(path)
      File.delete(path) rescue nil
      return [false, nil]
    end
    payload = JSON.parse(File.read(path))
    [true, payload['value']]
  rescue StandardError
    [false, nil]
  end

  def write(key, value)
    path = path_for(key)
    # Use the un-patched mkdir_p so the cache persists even under --dry-run/pretend:
    # a cache is a pure performance store, never a library change, so it must warm
    # up on dry-runs too (subsequent runs then skip the lookup/scan). The pretend
    # monkey-patch on FileUtils.mkdir_p would otherwise turn this into a no-op.
    if FileUtils.respond_to?(:mkdir_p_orig)
      FileUtils.mkdir_p_orig(File.dirname(path))
    else
      FileUtils.mkdir_p(File.dirname(path))
    end
    File.write(path, JSON.generate('key' => key.to_s, 'value' => value))
    value
  rescue StandardError => e
    @speaker&.tell_error(e, "JsonDiskCache write failed for '#{key}'") rescue nil
    value
  end

  def expired?(path)
    (Time.now - File.mtime(path)) > @ttl_days * 86_400
  rescue StandardError
    true
  end

  def path_for(key)
    digest = Digest::SHA1.hexdigest(key.to_s)
    File.join(@dir, digest[0, 2], "#{digest}.json")
  end
end

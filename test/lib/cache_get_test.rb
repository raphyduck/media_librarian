# frozen_string_literal: true

require_relative '../test_helper'

class CacheGetTtlTest < Minitest::Test
  # Minimal in-memory DB stand-in for the metadata_search rows that
  # Cache.cache_get reads and deletes.
  class FakeMetadataDb
    attr_reader :deleted

    def initialize(rows)
      @rows = rows.dup
      @deleted = []
    end

    def get_rows(table, conditions)
      return [] unless table.to_s == 'metadata_search'

      @rows.select do |r|
        conditions.all? { |k, v| r[k].to_s == v.to_s }
      end
    end

    def delete_rows(table, conditions)
      return unless table.to_s == 'metadata_search'

      removed = @rows.select { |r| conditions.all? { |k, v| r[k].to_s == v.to_s } }
      @rows -= removed
      @deleted.concat(removed)
    end
  end

  def setup
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    # Isolate the in-memory layer so earlier tests don't pollute this one.
    Cache.instance_variable_set(:@cache_metadata, Vash.new)
  end

  def teardown
    remove_app_reference(Cache)
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def test_stale_metadata_cache_is_expired_in_seconds_not_days
    # A row written two days ago must be treated as stale when the requested
    # TTL is 120 seconds. The old code used `.days`, which kept it alive.
    old_time = (Time.now - (2 * 86_400)).utc.iso8601
    db = FakeMetadataDb.new([
                              { type: 2, keywords: 'Vie privée|tt123|',
                                created_at: old_time, result: '["wrong title",null]' }
                            ])
    @environment.application.db = db

    result = Cache.cache_get('movie_lookup', 'Vie privée|tt123|', 120)

    assert_nil result, 'a 2-day-old entry should be expired with a 120-second TTL'
    refute_empty db.deleted, 'the stale row should have been purged'
  end

  def test_fresh_metadata_cache_is_returned
    recent_time = (Time.now - 30).utc.iso8601
    db = FakeMetadataDb.new([
                              { type: 2, keywords: 'Vie privée|tt123|',
                                created_at: recent_time, result: '["Vie privée",null]' }
                            ])
    @environment.application.db = db

    result = Cache.cache_get('movie_lookup', 'Vie privée|tt123|', 120)

    assert_equal ['Vie privée', nil], result
  end

  def test_pretend_mode_bypasses_cache_entirely
    recent_time = (Time.now - 30).utc.iso8601
    db = FakeMetadataDb.new([
                              { type: 2, keywords: 'Vie privée|tt123|',
                                created_at: recent_time, result: '["Vie privée",null]' }
                            ])
    @environment.application.db = db

    Env.stub(:pretend?, true) do
      result = Cache.cache_get('movie_lookup', 'Vie privée|tt123|', 120)
      assert_nil result, 'pretend mode must never read cached metadata'
    end
    assert_empty db.deleted, 'pretend mode must not purge cache rows either'
  end
end

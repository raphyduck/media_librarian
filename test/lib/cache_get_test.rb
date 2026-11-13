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

  def test_metadata_cache_is_fresh_within_day_ttl
    # movie_lookup uses 120 days: a 2-day-old row must still be valid.
    old_time = (Time.now - (2 * 86_400)).utc.iso8601
    db = FakeMetadataDb.new([
                              { type: 2, keywords: 'Vie privée|tt123|',
                                created_at: old_time, result: '["Vie privée",null]' }
                            ])
    @environment.application.db = db

    result = Cache.cache_get('movie_lookup', 'Vie privée|tt123|', 120)

    assert_equal ['Vie privée', nil], result
    assert_empty db.deleted
  end

  def test_tv_episodes_cache_expires_after_one_day
    # tv_episodes_search uses 1 day: a 2-day-old row must be purged.
    old_time = (Time.now - (2 * 86_400)).utc.iso8601
    db = FakeMetadataDb.new([
                              { type: 4, keywords: 'Some Show',
                                created_at: old_time, result: '["Some Show",[]]' }
                            ])
    @environment.application.db = db

    result = Cache.cache_get('tv_episodes_search', 'Some Show', 1)

    assert_nil result, 'a 2-day-old entry should be expired with a 1-day TTL'
    refute_empty db.deleted, 'the stale row should have been purged'
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

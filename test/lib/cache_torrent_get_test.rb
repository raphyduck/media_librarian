# frozen_string_literal: true

require_relative '../test_helper'

class CacheTorrentGetTest < Minitest::Test
  class FakeTorrentsDb
    attr_reader :deleted

    def initialize(rows)
      @rows = rows.dup
      @deleted = []
    end

    def get_rows(_table, _selector = {}, extra = {})
      like = extra['identifier like']
      @rows.select do |r|
        like.nil? || r[:identifier].to_s.downcase.include?(like.to_s.downcase.delete('%'))
      end
    end

    def delete_rows(_selector, conditions)
      removed = @rows.select { |r| conditions.all? { |k, v| r[k].to_s == v.to_s } }
      @rows -= removed
      @deleted.concat(removed)
      removed.size
    end
  end

  def setup
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Cache.instance_variable_set(:@cache_metadata, Vash.new)
  end

  def teardown
    remove_app_reference(Cache)
    remove_app_reference(TorrentSearch)
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def build_row(name:, identifier:, status:, tattributes:)
    {
      name: name,
      identifier: identifier,
      status: status,
      tattributes: Cache.object_pack(tattributes),
      created_at: Time.now.utc.iso8601
    }
  end

  def test_torrent_get_returns_completed_but_not_failed_rows
    db = FakeTorrentsDb.new([
      build_row(name: 'Done.1080p', identifier: 'movieX2025', status: 4,
                tattributes: { name: 'Done.1080p', added: Time.now.utc.iso8601,
                               timeframe_quality: 0, timeframe_size: 0, timeframe_tracker: 0 }),
      build_row(name: 'Failed.2160p', identifier: 'movieX2025', status: 6,
                tattributes: { name: 'Failed.2160p', added: Time.now.utc.iso8601,
                               timeframe_quality: 0, timeframe_size: 0, timeframe_tracker: 0 })
    ])
    @environment.application.db = db

    TorrentSearch.stub(:waiting_time_set, Time.now.utc.iso8601) do
      TorrentSearch.stub(:download_now?, 0) do
        results = Cache.torrent_get('movieX2025')
        names = results.map { |r| r[:name] }

        assert_includes names, 'Done.1080p', 'completed row must still be returned'
        refute_includes names, 'Failed.2160p', 'failed row must be hidden so a fresh release can be chosen'
      end
    end
  end

  def test_torrent_get_failed_row_does_not_shadow_other_identifiers
    db = FakeTorrentsDb.new([
      build_row(name: 'Failed.1080p', identifier: 'movieY2025', status: 6,
                tattributes: { name: 'Failed.1080p', added: Time.now.utc.iso8601,
                               timeframe_quality: 0, timeframe_size: 0, timeframe_tracker: 0 })
    ])
    @environment.application.db = db

    TorrentSearch.stub(:waiting_time_set, Time.now.utc.iso8601) do
      TorrentSearch.stub(:download_now?, 0) do
        results = Cache.torrent_get('movieY2025')

        assert_empty results, 'a failed row must not pretend the media is already present'
      end
    end
  end
end

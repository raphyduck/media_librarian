# frozen_string_literal: true

require 'test_helper'
require 'time'
require_relative '../../lib/string_utils'
require_relative '../../lib/metadata'
require_relative '../../app/torrent_search'

class TorrentSearchTest < Minitest::Test
  def setup
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    # TorrentSearch memoizes its app at the class level, so pin it to this test's
    # environment (otherwise the first test's app leaks into later ones).
    TorrentSearch.configure(app: @environment.application)
  end

  def teardown
    remove_app_reference(TorrentSearch)
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def with_identity_real_title
    Metadata.stub(:detect_real_title, ->(name, *_) { name }) do
      yield
    end
  end

  def test_search_keywords_include_ascii_folded_variant_for_accented_titles
    with_identity_real_title do
      keywords = TorrentSearch.search_keywords_for(['Chasse Gardée'], 'movies')

      assert_equal [{ :s => 'Chasse Gardée' }, { :s => 'Chasse Gardee' }], keywords
    end
  end

  def test_search_keywords_fold_typographic_apostrophes
    with_identity_real_title do
      keywords = TorrentSearch.search_keywords_for(['L’Âme Idéale'], 'movies')

      assert_includes keywords, { :s => "L'Ame Ideale" }
    end
  end

  def test_search_keywords_have_no_duplicate_for_ascii_titles
    with_identity_real_title do
      keywords = TorrentSearch.search_keywords_for(['Hunting Ground'], 'movies')

      assert_equal [{ :s => 'Hunting Ground' }], keywords
    end
  end

  # Minimal in-memory stand-in for Storage::Db covering the calls torrent_download makes.
  class FakeTorrentsDb
    attr_reader :rows
    def initialize(rows); @rows = rows; end
    def get_rows(_table, selector = {}, _extra = {})
      @rows.select { |r| selector.all? { |k, v| r[k].to_s == v.to_s } }
    end
    def insert_row(_table, row); @rows << row; end
    def update_rows(_table, attrs, selector)
      get_rows(_table, selector).each { |r| r.merge!(attrs) }
    end
    def delete_rows(_table, selector)
      doomed = get_rows(_table, selector)
      @rows.reject! { |r| doomed.include?(r) }
      doomed.size
    end
    def touch_rows(*); end
  end

  def test_download_removes_pending_siblings_but_keeps_active_ones
    db = FakeTorrentsDb.new([
      { :name => 'Movie.2025.720p.WEBRip', :identifier => 'movieMovie2025', :status => 1 },
      { :name => 'Movie.2025.1080p.WEBRip', :identifier => 'movieMovie2025', :status => 1 },
      { :name => 'Movie.2025.2160p.WEB',    :identifier => 'movieMovie2025', :status => 3, :torrent_id => 'tid1' }
    ])
    @environment.application.db = db

    chosen = {
      :name => 'Movie.2025.1080p.BluRay', :identifier => 'movieMovie2025',
      :tracker => 'c411', :added => '2020-01-01T00:00:00Z',
      :timeframe_quality => 0, :timeframe_size => 0, :timeframe_tracker => 0
    }

    TorrentSearch.torrent_download(chosen, 1, 1, [], 'movies')

    names = db.rows.map { |r| r[:name] }
    refute_includes names, 'Movie.2025.720p.WEBRip', 'pending sibling should be removed'
    refute_includes names, 'Movie.2025.1080p.WEBRip', 'pending sibling should be removed'
    assert_includes names, 'Movie.2025.2160p.WEB', 'active (status>=2) sibling must be kept'
    chosen_row = db.rows.find { |r| r[:name] == 'Movie.2025.1080p.BluRay' }
    assert chosen_row, 'chosen torrent should be persisted'
    assert_equal 2, chosen_row[:status], 'chosen torrent should be queued for download'
  end

  def test_promote_ready_downloads_promotes_only_recently_expired_timeframes
    iso = ->(t) { t.strftime('%Y-%m-%dT%H:%M:%SZ') }
    now = Time.now
    db = FakeTorrentsDb.new([
      # timeframe elapsed yesterday -> should be promoted
      { :name => 'Ready.Expired', :identifier => 'movieA2025', :status => 1,
        :tattributes => { :added => iso.(now - 2 * 86_400), :timeframe_quality => 0,
                          :timeframe_tracker => 0, :timeframe_size => 86_400 } },
      # timeframe still in the future -> left waiting
      { :name => 'Still.Waiting', :identifier => 'movieB2025', :status => 1,
        :tattributes => { :added => iso.(now), :timeframe_quality => 30 * 86_400,
                          :timeframe_tracker => 0, :timeframe_size => 0 } },
      # expired long ago (> max age) -> left for pruning, not promoted
      { :name => 'Ancient.Stale', :identifier => 'movieC2025', :status => 1,
        :tattributes => { :added => iso.(now - 400 * 86_400), :timeframe_quality => 0,
                          :timeframe_tracker => 0, :timeframe_size => 0 } }
    ])
    @environment.application.db = db

    Cache.stub(:object_unpack, ->(v) { v }) do
      TorrentSearch.promote_ready_downloads
    end

    status = ->(name) { db.rows.find { |r| r[:name] == name }[:status] }
    assert_equal 2, status.('Ready.Expired'), 'expired timeframe should be promoted to the download queue'
    assert_equal 1, status.('Still.Waiting'), 'future timeframe must stay pending'
    assert_equal 1, status.('Ancient.Stale'), 'stale row must be left for pruning, not promoted'
  end

  def test_promote_ready_downloads_grabs_a_single_release_per_media
    iso = ->(t) { t.strftime('%Y-%m-%dT%H:%M:%SZ') }
    now = Time.now
    tf0 = ->(size) { { :added => iso.(now - 3 * 86_400), :timeframe_quality => 0,
                       :timeframe_tracker => 0, :timeframe_size => 0, :size => size } }
    db = FakeTorrentsDb.new([
      # same media, two expired releases -> only the best (largest) is promoted
      { :name => 'Film.2160p', :identifier => 'movieX2025', :status => 1, :tattributes => tf0.(20 * 1024**3) },
      { :name => 'Film.1080p', :identifier => 'movieX2025', :status => 1, :tattributes => tf0.(5 * 1024**3) },
      # different media already downloading -> must not get a second torrent queued
      { :name => 'Other.1080p', :identifier => 'movieY2025', :status => 1, :tattributes => tf0.(4 * 1024**3) },
      { :name => 'Other.Active', :identifier => 'movieY2025', :status => 3 }
    ])
    @environment.application.db = db

    Cache.stub(:object_unpack, ->(v) { v }) do
      TorrentSearch.promote_ready_downloads
    end

    names = db.rows.map { |r| r[:name] }
    assert_includes names, 'Film.2160p'
    refute_includes names, 'Film.1080p', 'the other pending version of the same film must be removed'
    assert_equal 2, db.rows.find { |r| r[:name] == 'Film.2160p' }[:status], 'only the best release is queued'
    assert_equal 1, db.rows.find { |r| r[:name] == 'Other.1080p' }[:status],
                 'a film already downloading must not get a second torrent queued'
  end
end

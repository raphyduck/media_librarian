# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/music_quality'
require_relative '../../app/music_search'

# Focused tests for the CSV import seeder-threshold hardening: the automatic
# import must reject near-dead releases (default 3 seeders, configurable via
# music.min_seeders) while the interactive search keeps its lenient default.
class MusicSearchTest < Minitest::Test
  def test_min_seeders_import_defaults_to_three
    with_music_config({}) do
      assert_equal 3, MusicSearch.min_seeders_import
    end
  end

  def test_min_seeders_import_reads_config
    with_music_config({ 'min_seeders' => 8 }) do
      assert_equal 8, MusicSearch.min_seeders_import
    end
  end

  def test_min_seeders_import_ignores_non_positive_config
    with_music_config({ 'min_seeders' => 0 }) do
      assert_equal 3, MusicSearch.min_seeders_import
    end
  end

  # import_csv must call search with the configured threshold, never the lenient
  # interactive default of 1.
  def test_import_csv_passes_default_min_seeders_to_search
    captured = capture_filter_dead(config: {}) do
      MusicSearch.import_csv(csv_content: +"query\nDaft Punk Discovery\n", detailed: true)
    end
    refute_includes captured, 1
    assert_equal [3], captured.uniq
  end

  def test_import_csv_passes_configured_min_seeders_to_search
    captured = capture_filter_dead(config: { 'min_seeders' => 5 }) do
      MusicSearch.import_csv(csv_content: +"query\nDaft Punk Discovery\n", detailed: true)
    end
    refute_includes captured, 1
    assert_equal [5], captured.uniq
  end

  # The artist fallback search must be held to the same threshold.
  def test_import_csv_fallback_search_also_uses_min_seeders
    captured = capture_filter_dead(config: { 'min_seeders' => 4 }, results_for: ->(kw) { kw == 'ABBA' ? [result('ABBA Discography [FLAC]', 9)] : [] }) do
      MusicSearch.import_csv(csv_content: +"Artiste,Album\nABBA,Missing One\n", detailed: true)
    end
    # one album query (miss) + one artist fallback query, both at threshold 4
    assert_equal [4], captured.uniq
    assert_equal 2, captured.size
  end

  # search(filter_dead: 3) keeps only releases with >= 3 seeders, sorted desc.
  def test_search_filter_dead_drops_low_seeder_results
    results = [result('A', 0), result('B', 1), result('C', 2), result('D', 5), result('E', 10)]
    svc = Object.new
    svc.define_singleton_method(:get_trackers) { |*| ['t1'] }
    svc.define_singleton_method(:get_site_keywords) { |*| '' }
    svc.define_singleton_method(:launch_search) { |*| results }

    with_music_config({}) do
      with_singletons(tracker_query_service: -> { svc }) do
        out = MusicSearch.search(keyword: 'x', filter_dead: 3, sources: ['t1'])
        assert_equal [10, 5], out.map { |t| t[:seeders].to_i }
      end
    end
  end

  private

  def result(name, seeders)
    { name: name, link: 'http://tracker.example/x.torrent', tracker: 't', seeders: seeders }
  end

  # Runs the block with search/queue_download stubbed under the given music
  # config, returning the list of filter_dead values search was called with.
  # results_for maps a search keyword to the results it should return.
  def capture_filter_dead(config:, results_for: ->(_kw) { [result('Match [FLAC]', 9)] })
    captured = []
    with_music_config(config) do
      with_singletons(
        search: lambda { |keyword:, filter_dead: 1, **_rest| captured << filter_dead; results_for.call(keyword) },
        queue_download: ->(**_a) { { 'queued' => 'ok' } }
      ) do
        yield
      end
    end
    captured
  end

  def build_app(music_hash)
    speaker = Object.new
    def speaker.speak_up(*); end
    def speaker.tell_error(*); end
    app = Object.new
    cfg = { 'music' => music_hash }
    app.define_singleton_method(:config) { cfg }
    app.define_singleton_method(:speaker) { speaker }
    app
  end

  def with_music_config(music_hash, &block)
    app = build_app(music_hash)
    with_singletons({ app: -> { app } }, &block)
  end

  # Replaces the given MusicSearch singleton methods for the duration of the
  # block, restoring the originals afterwards.
  def with_singletons(impls)
    sc = MusicSearch.singleton_class
    saved = {}
    impls.each_key do |m|
      saved[m] = sc.instance_method(m) if sc.method_defined?(m) || sc.private_method_defined?(m)
    end
    begin
      impls.each { |name, impl| MusicSearch.define_singleton_method(name, &impl) }
      yield
    ensure
      saved.each { |m, um| sc.send(:define_method, m, um) }
    end
  end
end

# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/music_quality'
require_relative '../../app/music_search'
require_relative '../../app/music_library'
require_relative '../../app/soulseek_search'

# Focused tests for the CSV import seeder-threshold hardening and the
# Soulseek-primary / tracker-fallback ordering. The automatic import rejects
# near-dead releases (default 3 seeders, configurable via music.min_seeders)
# while the interactive search keeps its lenient default.
class MusicSearchTest < Minitest::Test
  # Neutralise the real sockseek binary by default so a machine that actually
  # has it installed never launches it during the suite; the Soulseek-ordering
  # tests opt back in explicitly. Restored in teardown.
  def setup
    @__soulseek_available = SoulseekSearch.singleton_class.instance_method(:available?)
    SoulseekSearch.define_singleton_method(:available?) { false }
  end

  def teardown
    SoulseekSearch.singleton_class.send(:define_method, :available?, @__soulseek_available) if @__soulseek_available
  end

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

  # ---------- Soulseek-primary ordering (option B) ----------

  # primary + tracker_fallback: Soulseek gets the whole batch first; only its
  # misses reach the trackers.
  def test_primary_soulseek_falls_back_to_trackers_only_for_misses
    handed = nil
    searched = []
    app = build_app({ 'soulseek' => { 'enabled' => true, 'primary' => true, 'tracker_fallback' => true } })
    with_class_singletons(
      MusicSearch => {
        app: -> { app },
        search: lambda { |keyword:, **_r| searched << keyword; [{ name: "#{keyword} [FLAC]", link: 'l', tracker: 't', seeders: 9 }] },
        queue_download: ->(**_a) { { 'queued' => 'ok' } }
      },
      SoulseekSearch => {
        available?: -> { true },
        fetch: lambda { |entries:, **_r| handed = entries; { 'downloaded_entries' => ['A One', 'B Two'] } }
      }
    ) do
      report = MusicSearch.import_csv(csv_content: +"query\nA One\nB Two\nC Three\n", detailed: true)

      assert_equal ['A One', 'B Two', 'C Three'], handed.map { |e| e[:query] }, 'soulseek gets the whole batch first'
      assert_equal ['C Three'], searched, 'only the soulseek miss reaches the trackers'
      assert_equal 2, report['soulseek_downloaded']
      assert_equal ['A One', 'B Two'], report['soulseek_downloaded_entries']
      assert_equal 1, report['total_queued']
      assert_equal 0, report['not_found']
    end
  end

  # primary + tracker_fallback:false -> Soulseek only, no tracker recourse.
  def test_soulseek_only_makes_no_tracker_calls
    searched = []
    app = build_app({ 'soulseek' => { 'enabled' => true, 'primary' => true, 'tracker_fallback' => false } })
    with_class_singletons(
      MusicSearch => {
        app: -> { app },
        search: lambda { |**_r| searched << :search; [] },
        queue_download: ->(**_a) { { 'queued' => 'ok' } }
      },
      SoulseekSearch => {
        available?: -> { true },
        fetch: lambda { |entries:, **_r| { 'downloaded_entries' => ['A One'] } }
      }
    ) do
      report = MusicSearch.import_csv(csv_content: +"query\nA One\nB Two\n", detailed: true)

      assert_empty searched, 'no tracker calls in soulseek-only mode'
      assert_equal 1, report['soulseek_downloaded']
      assert_equal 0, report['total_queued']
      assert_equal ['B Two'], report['not_found_entries']
    end
  end

  # primary:false -> the legacy order (trackers first, Soulseek as fallback).
  def test_primary_false_uses_trackers_first
    order = []
    app = build_app({ 'soulseek' => { 'enabled' => true, 'primary' => false } })
    with_class_singletons(
      MusicSearch => {
        app: -> { app },
        search: lambda { |keyword:, **_r| order << :search; [{ name: "#{keyword} [FLAC]", link: 'l', tracker: 't', seeders: 9 }] },
        queue_download: ->(**_a) { { 'queued' => 'ok' } }
      },
      SoulseekSearch => {
        available?: -> { true },
        fetch: lambda { |entries:, **_r| order << :soulseek; { 'downloaded_entries' => [] } }
      }
    ) do
      report = MusicSearch.import_csv(csv_content: +"query\nSomething\n", detailed: true)

      assert_equal :search, order.first, 'trackers are tried first in legacy mode'
      refute_includes order, :soulseek, 'a tracker hit leaves no candidate for the soulseek fallback'
      assert_equal 1, report['total_queued']
    end
  end

  # --then_organize runs organize once after the import; off by default.
  def test_then_organize_flag_runs_organize_after_import
    app = build_app({ 'soulseek' => { 'enabled' => true, 'primary' => true, 'tracker_fallback' => false } })
    soulseek = { available?: -> { true }, fetch: ->(entries:, **_r) { { 'downloaded_entries' => ['A One'] } } }

    with_flag = []
    with_class_singletons(
      MusicSearch => { app: -> { app } },
      SoulseekSearch => soulseek,
      MusicLibrary => { organize: ->(*_a, **_k) { with_flag << :organize; { 'organized' => 1 } } }
    ) do
      MusicSearch.import_csv(csv_content: +"query\nA One\n", detailed: true, then_organize: '1')
    end
    assert_equal [:organize], with_flag, 'organize runs once when --then_organize is set'

    without_flag = []
    with_class_singletons(
      MusicSearch => { app: -> { app } },
      SoulseekSearch => soulseek,
      MusicLibrary => { organize: ->(*_a, **_k) { without_flag << :organize; {} } }
    ) do
      MusicSearch.import_csv(csv_content: +"query\nA One\n", detailed: true)
    end
    assert_empty without_flag, 'organize does not run by default'
  end

  def test_flag_true_recognizes_common_values
    %w[1 true yes on TRUE].each { |v| assert MusicSearch.flag_true?(v), v }
    [nil, false, '', '0', 'false', 'no', 'off'].each { |v| refute MusicSearch.flag_true?(v), v.inspect }
  end

  private

  def result(name, seeders)
    { name: name, link: 'http://tracker.example/x.torrent', tracker: 't', seeders: seeders }
  end

  # Like with_singletons but across multiple classes: { Klass => { method => impl } }.
  def with_class_singletons(overrides)
    saved = []
    overrides.each do |klass, methods|
      sc = klass.singleton_class
      methods.each_key do |m|
        saved << [sc, m, sc.instance_method(m)] if sc.method_defined?(m) || sc.private_method_defined?(m)
      end
    end
    begin
      overrides.each { |klass, methods| methods.each { |m, impl| klass.define_singleton_method(m, &impl) } }
      yield
    ensure
      saved.each { |sc, m, um| sc.send(:define_method, m, um) }
    end
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

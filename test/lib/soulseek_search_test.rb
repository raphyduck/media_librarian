# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

require_relative '../test_helper'
require_relative '../../lib/music_quality'
require_relative '../../app/music_search'
require_relative '../../app/soulseek_search'

# Tests for the Soulseek (sockseek) fallback: availability gating, safe
# non-interactive command construction + index parsing, and the import_csv
# wiring that hands only tracker misses to the fallback and reports three ways.
class SoulseekSearchTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('sockseek-test')
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && Dir.exist?(@tmp)
  end

  # ---------- available? ----------

  def test_available_true_when_binary_and_config_exist
    bin = touch('sockseek')
    conf = touch('sockseek.conf')
    with_soulseek_app(binary: bin, config: conf) do
      assert SoulseekSearch.available?
    end
  end

  def test_available_false_when_binary_missing
    conf = touch('sockseek.conf')
    with_soulseek_app(binary: File.join(@tmp, 'absent'), config: conf) do
      refute SoulseekSearch.available?
    end
  end

  def test_available_false_when_config_missing
    bin = touch('sockseek')
    with_soulseek_app(binary: bin, config: File.join(@tmp, 'absent.conf')) do
      refute SoulseekSearch.available?
    end
  end

  def test_available_false_when_disabled
    bin = touch('sockseek')
    conf = touch('sockseek.conf')
    with_soulseek_app(binary: bin, config: conf, enabled: false) do
      refute SoulseekSearch.available?
    end
  end

  # ---------- fetch ----------

  def test_fetch_builds_safe_command_and_parses_index
    bin = touch('sockseek')
    conf = touch('sockseek.conf')
    captured = nil
    input_csv = nil
    organized = []

    run = lambda do |*args|
      captured = args
      input_csv = File.read(args[args.index('--input') + 1])
      File.write(args[args.index('--index-path') + 1],
                 "artist,album,title,state\nRenaud,Mistral Gagnant,,1\nFoo,Bar,,2\n")
      ['done', '', build_status(0)]
    end

    with_soulseek_app(binary: bin, config: conf) do
      Open3.stub(:capture3, run) do
        MusicSearch.stub(:music_destination, '/library/Music') do
          MusicSearch.stub(:music_staging, @tmp) do
            MusicLibrary.stub(:organize, ->(*_a, **k) { organized << k[:source]; {} }) do
              report = SoulseekSearch.fetch(
                entries: [{ artist: 'Renaud', album: 'Mistral Gagnant' }, { artist: 'Foo', album: 'Bar' }],
                quality: 'flac'
              )

              # Command safety: binary first, expected flags present, NO --interactive.
              assert_equal bin, captured.first
              assert_equal 'flac', arg_after(captured, '--pref-format')
              assert_equal '/library/Music', arg_after(captured, '--skip-music-dir')
              assert_includes captured, '--no-progress'
              assert_includes captured, '--skip-existing'
              assert_equal %w[csv], [arg_after(captured, '--input-type')]
              refute_includes captured, '--interactive'

              # Input CSV is well-formed for sockseek (Artist,Title,Album).
              assert_equal 'Artist,Title,Album', input_csv.lines.first.strip
              assert_includes input_csv, 'Renaud'
              assert_includes input_csv, 'Mistral Gagnant'

              # Index parsing -> per-entry classification.
              assert_equal 2, report['attempted']
              assert_equal 1, report['downloaded']
              assert_equal 1, report['failed']
              assert_equal ['Renaud Mistral Gagnant'], report['downloaded_entries']
              assert_equal ['Foo Bar'], report['failed_entries']

              # Downloads were filed from the staging folder.
              assert_equal [@tmp], organized
            end
          end
        end
      end
    end
  end

  def test_fetch_is_inert_when_unavailable
    with_soulseek_app(binary: File.join(@tmp, 'absent'), config: File.join(@tmp, 'absent.conf')) do
      report = SoulseekSearch.fetch(entries: [{ artist: 'A', album: 'B' }], quality: 'flac')
      assert_equal 0, report['downloaded']
      assert_empty report['downloaded_entries']
    end
  end

  # ---------- import_csv wiring ----------

  def test_import_csv_hands_only_misses_to_soulseek_and_reports_three_ways
    handed = nil
    app = build_app(config: { 'music' => {} })
    overrides = {
      MusicSearch => {
        app: -> { app },
        search: lambda { |keyword:, **_r|
          keyword.include?('HIT') ? [{ name: "#{keyword} [FLAC]", link: 'l', tracker: 't', seeders: 9 }] : []
        },
        queue_download: ->(**_a) { { 'queued' => 'ok' } }
      },
      SoulseekSearch => {
        available?: -> { true },
        fetch: lambda { |entries:, **_r|
          handed = entries
          { 'downloaded_entries' => ['MISS One'], 'failed_entries' => ['MISS Two'],
            'attempted' => 2, 'downloaded' => 1, 'failed' => 1 }
        }
      }
    }

    with_singletons(overrides) do
      report = MusicSearch.import_csv(csv_content: +"query\nHIT Album\nMISS One\nMISS Two\n", detailed: true)

      assert_equal 1, report['total_queued'], 'tracker-queued'
      assert_equal 1, report['soulseek_queued'], 'soulseek-queued'
      assert_equal ['MISS One'], report['soulseek_queued_entries']
      assert_equal 1, report['not_found'], 'still not found'
      assert_equal ['MISS Two'], report['not_found_entries']

      # Only the tracker misses were handed to Soulseek, never the tracker hit.
      handed_queries = handed.map { |e| e[:query] }
      refute_includes handed_queries, 'HIT Album'
      assert_equal ['MISS One', 'MISS Two'], handed_queries.sort
    end
  end

  private

  def touch(name)
    path = File.join(@tmp, name)
    File.write(path, '')
    path
  end

  def arg_after(args, flag)
    idx = args.index(flag)
    idx ? args[idx + 1] : nil
  end

  def build_status(code)
    status = Object.new
    status.define_singleton_method(:success?) { code.zero? }
    status.define_singleton_method(:exitstatus) { code }
    status
  end

  def build_app(config:)
    speaker = Object.new
    def speaker.speak_up(*); end
    def speaker.tell_error(*); end
    app = Object.new
    app.define_singleton_method(:config) { config }
    app.define_singleton_method(:speaker) { speaker }
    app
  end

  def with_soulseek_app(binary:, config:, enabled: true, &block)
    soulseek = { 'enabled' => enabled, 'binary' => binary, 'config' => config }
    app = build_app(config: { 'music' => { 'soulseek' => soulseek } })
    with_singletons({ SoulseekSearch => { app: -> { app } } }, &block)
  end

  # overrides: { Klass => { method_name => impl_lambda } }. Replaces the given
  # singleton methods for the block and restores the originals afterwards.
  def with_singletons(overrides)
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
end

# frozen_string_literal: true

require 'tmpdir'
require 'ostruct'
require 'stringio'
require 'fileutils'

require_relative '../test_helper'
require_relative '../../lib/storage/db'

class FixTorznabLinksScriptTest < Minitest::Test
  def setup
    reset_librarian_state!
    @cache_stub = Cache if Object.const_defined?(:Cache)
    Object.send(:remove_const, :Cache) if Object.const_defined?(:Cache)
    load File.expand_path('../../lib/cache.rb', __dir__)
    load File.expand_path('../../scripts/fix_torznab_links.rb', __dir__)
    @tmp_dir = Dir.mktmpdir('fix-torznab-links-test')
    @db_path = File.join(@tmp_dir, 'test.db')
    @speaker = TestSupport::Fakes::Speaker.new
    @app = OpenStruct.new(
      db: Storage::Db.new(@db_path),
      speaker: @speaker,
      env_flags: {}
    )
    MediaLibrarian.application = @app
  end

  def teardown
    Object.send(:remove_const, :Cache) if Object.const_defined?(:Cache)
    Object.const_set(:Cache, @cache_stub) if @cache_stub
    MediaLibrarian.application = nil
    @app&.db&.database&.disconnect
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir && Dir.exist?(@tmp_dir)
  end

  def test_swaps_links_for_active_torrents
    attrs = {
      link: 'https://example.com/download/1',
      torrent_link: 'https://example.com/details/1'
    }

    packed = Cache.object_pack(attrs)
    @app.db.insert_row('torrents', { name: 'fix-me', status: 2, tattributes: packed })
    @app.db.insert_row('torrents', { name: 'skip-me', status: 0, tattributes: packed })

    output = StringIO.new
    fixed = fix_torznab_links(@app.db, out: output)

    assert_equal 1, fixed

    updated = @app.db.get_rows('torrents', { name: 'fix-me' }).first
    unpacked = Cache.object_unpack(updated[:tattributes])
    assert_equal 'https://example.com/details/1', unpacked[:link]
    assert_equal 'https://example.com/download/1', unpacked[:torrent_link]

    untouched = @app.db.get_rows('torrents', { name: 'skip-me' }).first
    assert_equal attrs[:link], Cache.object_unpack(untouched[:tattributes])[:link]

    assert_includes output.string, 'Fixed 1 torrent'
  end
end

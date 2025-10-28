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
    @original_home = ENV['HOME']
    @home_dir = Dir.mktmpdir('fix-torznab-links-home')
    ENV['HOME'] = @home_dir

    @original_application = MediaLibrarian.instance_variable_get(:@application) if MediaLibrarian.instance_variable_defined?(:@application)
    if defined?(MediaLibrarian::Boot)
      @original_boot_application = MediaLibrarian::Boot.instance_variable_get(:@application) if MediaLibrarian::Boot.instance_variable_defined?(:@application)
      @original_boot_container = MediaLibrarian::Boot.instance_variable_get(:@container) if MediaLibrarian::Boot.instance_variable_defined?(:@container)
    end

    unless Object.const_defined?(:SPACE_SUBSTITUTE)
      @defined_space_substitute = true
      Object.const_set(:SPACE_SUBSTITUTE, '\\. _\\-')
    end
    unless Object.const_defined?(:VALID_VIDEO_EXT)
      @defined_valid_video_ext = true
      Object.const_set(:VALID_VIDEO_EXT, '(.*)\\.(mkv)$')
    end
    unless Object.const_defined?(:BASIC_EP_MATCH)
      @defined_basic_ep_match = true
      Object.const_set(:BASIC_EP_MATCH, 'S(\\d{2})E(\\d{2})')
    end

    @cache_stub = Object.const_get(:Cache) if Object.const_defined?(:Cache)
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
    if defined?(MediaLibrarian::Boot)
      MediaLibrarian::Boot.instance_variable_set(:@application, @app)
      MediaLibrarian::Boot.instance_variable_set(:@container, nil)
    end
  end

  def teardown
    MediaLibrarian.instance_variable_set(:@application, @original_application)
    if defined?(MediaLibrarian::Boot)
      MediaLibrarian::Boot.instance_variable_set(:@application, @original_boot_application)
      MediaLibrarian::Boot.instance_variable_set(:@container, @original_boot_container)
    end
    MediaLibrarian.application = nil
    @app&.db&.database&.disconnect
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir && Dir.exist?(@tmp_dir)
    ENV['HOME'] = @original_home if defined?(@original_home)
    FileUtils.remove_entry(@home_dir) if defined?(@home_dir) && @home_dir && Dir.exist?(@home_dir)
    Object.send(:remove_const, :Cache) if Object.const_defined?(:Cache)
    Object.const_set(:Cache, @cache_stub) if defined?(@cache_stub) && @cache_stub
    Object.send(:remove_const, :BASIC_EP_MATCH) if defined?(@defined_basic_ep_match) && Object.const_defined?(:BASIC_EP_MATCH)
    Object.send(:remove_const, :VALID_VIDEO_EXT) if defined?(@defined_valid_video_ext) && Object.const_defined?(:VALID_VIDEO_EXT)
    Object.send(:remove_const, :SPACE_SUBSTITUTE) if defined?(@defined_space_substitute) && Object.const_defined?(:SPACE_SUBSTITUTE)
  end

  def test_swaps_detail_links_into_torrent_link
    attrs = {
      link: 'https://example.com/details/1',
      torrent_link: 'https://example.com/download/1'
    }

    packed = Cache.object_pack(attrs)
    @app.db.insert_row('torrents', { name: 'fix-me', status: 2, tattributes: packed })
    @app.db.insert_row('torrents', { name: 'skip-me', status: 0, tattributes: packed })

    output = StringIO.new
    fixed = fix_torznab_links(@app.db, out: output)

    assert_equal 1, fixed

    updated = @app.db.get_rows('torrents', { name: 'fix-me' }).first
    unpacked = Cache.object_unpack(updated[:tattributes])
    assert_equal 'https://example.com/download/1', unpacked[:link]
    assert_equal 'https://example.com/details/1', unpacked[:torrent_link]

    untouched = @app.db.get_rows('torrents', { name: 'skip-me' }).first
    assert_equal attrs[:link], Cache.object_unpack(untouched[:tattributes])[:link]

    assert_includes output.string, 'Fixed 1 torrent'
  end

  def test_leaves_existing_download_links_alone
    attrs = {
      link: 'https://example.com/download/2',
      torrent_link: 'https://example.com/details/2'
    }

    packed = Cache.object_pack(attrs)
    @app.db.insert_row('torrents', { name: 'correct', status: 2, tattributes: packed })

    output = StringIO.new
    fixed = fix_torznab_links(@app.db, out: output)

    assert_equal 0, fixed

    updated = @app.db.get_rows('torrents', { name: 'correct' }).first
    unpacked = Cache.object_unpack(updated[:tattributes])
    assert_equal attrs[:link], unpacked[:link]
    assert_equal attrs[:torrent_link], unpacked[:torrent_link]

    assert_includes output.string, 'Fixed 0 torrents'
  end
end

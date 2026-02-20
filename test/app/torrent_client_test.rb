# frozen_string_literal: true

require 'test_helper'
require 'base64'
require_relative '../../app/torrent_client'

class TorrentClientTest < Minitest::Test
  class RecordingDelugeClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def add_torrent_file(*args)
      @calls << [:add_torrent_file, args]
    end

    def add_torrent_magnet(*args)
      @calls << [:add_torrent_magnet, args]
    end

    def add_torrent_url(*args)
      @calls << [:add_torrent_url, args]
    end

    def get_torrent_status(*args)
      @calls << [:get_torrent_status, args]
      { 'name' => 'test', 'progress' => 100, 'queue' => 1 }
    end

    def queue_top(*args)
      @calls << [:queue_top, args]
    end

    def rename_files(*args)
      @calls << [:rename_files, args]
    end
  end

  class FakeApp
    attr_accessor :speaker, :t_client, :config

    def initialize(speaker:, t_client:)
      @speaker = speaker
      @t_client = t_client
      @config = { 'deluge' => { 'host' => 'localhost', 'username' => 'test', 'password' => 'test' } }
    end
  end

  def setup
    @speaker = TestSupport::Fakes::Speaker.new
    @recording_client = RecordingDelugeClient.new
    @app = FakeApp.new(speaker: @speaker, t_client: @recording_client)
    @torrent_client = TorrentClient.new(app: @app)
  end

  def test_download_file_does_not_pass_main_only_to_deluge
    download = { type: 1, filename: 'test.torrent', file: 'torrent-data' }
    options = {
      move_completed: '/home/user/completed/Movies/',
      main_only: 1,
      rename_main: 'SomeMovie',
      tdid: '12345',
      queue: 'top'
    }

    @torrent_client.download_file(download, options.deep_dup)

    assert_equal 1, @recording_client.calls.length
    method_name, args = @recording_client.calls.first
    assert_equal :add_torrent_file, method_name

    passed_options = args.last
    assert_instance_of Hash, passed_options
    refute passed_options.key?(:main_only), "main_only symbol key should not be passed to Deluge"
    refute passed_options.key?('main_only'), "main_only string key should not be passed to Deluge"
  end

  def test_download_file_passes_valid_deluge_options
    download = { type: 1, filename: 'test.torrent', file: 'torrent-data' }
    options = {
      move_completed: '/home/user/completed/Movies/',
      main_only: 1
    }

    @torrent_client.download_file(download, options.deep_dup)

    _, args = @recording_client.calls.first
    passed_options = args.last
    assert_equal true, passed_options['move_completed'] || passed_options[:move_completed]
    move_path = passed_options['move_completed_path'] || passed_options[:move_completed_path]
    assert_equal '/home/user/completed/Movies/', move_path
    add_paused = passed_options['add_paused'] || passed_options[:add_paused]
    assert_equal true, add_paused
  end

  def test_download_file_strips_non_deluge_options
    download = { type: 1, filename: 'test.torrent', file: 'torrent-data' }
    options = {
      move_completed: '/home/user/completed/',
      main_only: 1,
      rename_main: 'SomeName',
      tdid: '999',
      queue: 'top',
      assume_quality: 'HD',
      entry_id: 'abc',
      category: 'movies',
      whitelisted_extensions: ['mkv']
    }

    @torrent_client.download_file(download, options.deep_dup)

    _, args = @recording_client.calls.first
    passed_options = args.last
    all_keys = passed_options.keys.map(&:to_s)

    %w[main_only rename_main tdid queue assume_quality entry_id category whitelisted_extensions].each do |key|
      refute all_keys.include?(key), "#{key} should not be passed to Deluge"
    end
  end

  def test_download_file_magnet_does_not_pass_main_only
    download = { type: 2, url: 'magnet:?xt=urn:btih:abc123' }
    options = {
      move_completed: '/home/user/completed/',
      main_only: 1
    }

    @torrent_client.download_file(download, options.deep_dup)

    assert_equal 1, @recording_client.calls.length
    method_name, args = @recording_client.calls.first
    assert_equal :add_torrent_magnet, method_name

    passed_options = args.last
    refute passed_options.key?(:main_only), "main_only symbol key should not be passed to Deluge"
    refute passed_options.key?('main_only'), "main_only string key should not be passed to Deluge"
  end

  def test_rename_torrent_files_with_non_ascii_directory_name
    tid = 'abc123'
    korean_dir = '어쩔수가없다 (2025)'
    files = [{ 'index' => 0, 'path' => 'No.Other.Choice.2025.mkv' }]

    @torrent_client.rename_torrent_files(tid, files, korean_dir)

    assert_equal 1, @recording_client.calls.length
    method_name, args = @recording_client.calls.first
    assert_equal :rename_files, method_name
    paths = args[1]
    assert_equal 1, paths.length
    new_path = paths[0][1]
    assert new_path.valid_encoding?, "new_path must have valid encoding"
    assert_includes new_path, 'No.Other.Choice.2025.mkv'
  end

  def test_rename_torrent_files_with_ascii_8bit_directory_name
    tid = 'abc123'
    korean_dir = '어쩔수가없다 (2025)'.dup.force_encoding('ASCII-8BIT')
    files = [{ 'index' => 0, 'path' => 'No.Other.Choice.2025.mkv' }]

    @torrent_client.rename_torrent_files(tid, files, korean_dir)

    assert_equal 1, @recording_client.calls.length
    _, args = @recording_client.calls.first
    paths = args[1]
    new_path = paths[0][1]
    assert new_path.valid_encoding?, "new_path must have valid encoding after fix_encoding on ASCII-8BIT dir name"
  end

  def test_binarize_strings_forces_ascii_8bit_on_strings
    result = @torrent_client.send(:binarize_strings, 'hello')
    assert_equal Encoding::ASCII_8BIT, result.encoding
    assert_equal 'hello', result
  end

  def test_binarize_strings_recurses_into_arrays
    result = @torrent_client.send(:binarize_strings, ['hello', ['world']])
    assert_equal Encoding::ASCII_8BIT, result[0].encoding
    assert_equal Encoding::ASCII_8BIT, result[1][0].encoding
  end

  def test_binarize_strings_recurses_into_hashes
    result = @torrent_client.send(:binarize_strings, { 'key' => 'value' })
    assert_equal Encoding::ASCII_8BIT, result['key'].encoding
    assert_equal Encoding::ASCII_8BIT, result['value'].encoding
  end

  def test_binarize_strings_preserves_utf8_bytes_as_binary
    utf8_str = '어쩔수가없다'
    result = @torrent_client.send(:binarize_strings, utf8_str)
    assert_equal Encoding::ASCII_8BIT, result.encoding
    assert_equal utf8_str.b, result
  end

  def test_binarize_strings_leaves_non_strings_untouched
    result = @torrent_client.send(:binarize_strings, [0, 42, nil, true])
    assert_equal 0, result[0]
    assert_equal 42, result[1]
    assert_nil result[2]
    assert_equal true, result[3]
  end
end

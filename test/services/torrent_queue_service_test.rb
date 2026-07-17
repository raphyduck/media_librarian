# frozen_string_literal: true

require 'tmpdir'

require_relative 'service_test_helper'
require_relative '../../app/media_librarian/services'
require_relative '../../app/media_librarian/services/base_service'
require_relative '../../app/media_librarian/services/torrent_queue_service'

class Cache; end unless defined?(Cache)
%i[queue_state_get queue_state_shift queue_state_select queue_state_remove].each do |method_name|
  next if Cache.respond_to?(method_name)

  Cache.define_singleton_method(method_name) { |*_, &_blk| method_name == :queue_state_shift ? nil : {} }
end

unless defined?(TorrentSearch)
  class TorrentSearch
    class << self
      def get_tracker_config(*)
        {}
      end

      def get_torrent_file(*, **)
        ''
      end
    end
  end
end

class TorrentQueueServiceTest < Minitest::Test
  class FakeDB
    attr_reader :updated_rows

    def initialize
      @updated_rows = []
    end

    def get_rows(*_args)
      []
    end

    def update_rows(*args)
      @updated_rows << args
    end
  end

  class FakeClient
    def delete_torrent(*); end
    def download_file(*); end
  end

  class FakeApp
    attr_accessor :db, :temp_dir

    def initialize(db:, temp_dir: Dir.tmpdir)
      @db = db
      @temp_dir = temp_dir
    end
  end

  def setup
    @speaker = TestSupport::Fakes::Speaker.new
    @db = FakeDB.new
    @app = FakeApp.new(db: @db)
    @service = MediaLibrarian::Services::TorrentQueueService.new(
      app: @app,
      speaker: @speaker,
      client: FakeClient.new
    )
  end

  def test_process_added_torrents_survives_torrent_gone_from_client
    added = ['tid-gone']
    t_client = Object.new
    t_client.define_singleton_method(:get_torrent_status) { |*_| {} }
    closeness = Object.new
    closeness.define_singleton_method(:getDistance) { |*_| raise 'fuzzy matching must not run without a torrent name' }
    @app.define_singleton_method(:t_client) { t_client }
    @app.define_singleton_method(:str_closeness) { closeness }

    options_queue = { 'Some.Torrent.Name' => { info_hash: 'other-hash' } }
    Cache.stub(:queue_state_get, ->(queue) { queue == 'deluge_torrents_added' ? added : options_queue }) do
      Cache.stub(:queue_state_shift, ->(_) { added.shift }) do
        Cache.stub(:queue_state_select, ->(_q, *_, &blk) { options_queue.select { |k, v| blk.call(k, v) } }) do
          @service.process_added_torrents
        end
      end
    end

    errors = @speaker.messages.select { |m| m.is_a?(Array) && m.first == :error }
    assert_empty errors, "no error expected when the torrent is gone: #{errors.inspect}"
  end

  def test_process_download_request_updates_database_when_no_download
    request = MediaLibrarian::Services::TorrentDownloadRequest.new(
      torrent_name: 'test',
      torrent_type: 1,
      path: 'nodl',
      options: {},
      tracker: 'tracker',
      nodl: 1,
      queue_file_handling: {}
    )

    Cache.stub(:queue_state_add_or_update, nil) do
      Cache.stub(:queue_state_remove, nil) do
        assert @service.process_download_request(request)
      end
    end

    refute_empty @db.updated_rows
    table, values, conditions = @db.updated_rows.first
    assert_equal 'torrents', table
    assert_equal({ name: 'test' }, conditions)
    assert_equal 3, values[:status]
    refute_nil values[:torrent_id]
  end

  def test_process_download_request_skips_add_when_already_in_client
    # Minimal valid torrent payload: {'info' => {'name' => 'x'}}.
    path = File.join(Dir.tmpdir, "queue_precheck_#{Process.pid}.torrent")
    File.binwrite(path, 'd4:infod4:name1:xee')

    t_client = Object.new
    def t_client.get_torrent_status(*)
      { 'name' => 'x' }
    end
    app = FakeApp.new(db: @db)
    app.define_singleton_method(:t_client) { t_client }

    client = FakeClient.new
    added = []
    client.define_singleton_method(:download_file) { |*args| added << args }

    service = MediaLibrarian::Services::TorrentQueueService.new(
      app: app, speaker: @speaker, client: client
    )
    request = MediaLibrarian::Services::TorrentDownloadRequest.new(
      torrent_name: 'already-there', torrent_type: 1, path: path,
      options: {}, tracker: 't', nodl: 0, queue_file_handling: {}
    )

    result = nil
    Cache.stub(:queue_state_add_or_update, nil) do
      Cache.stub(:queue_state_remove, nil) do
        result = service.process_download_request(request)
      end
    end

    assert result
    assert_empty added, 'download_file must not be called when the torrent is already in the client'
    assert(@db.updated_rows.any? { |(table, values, _c)| table == 'torrents' && values[:status] == 3 },
           'the row must be reconciled to status 3')
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_parse_pending_downloads_uses_link_url
    torrent_attributes = {
      link: 'https://primary.example/download',
      tracker: 'tracker',
      magnet_link: '',
      files: [],
      move_completed: '',
      rename_main: '',
      queue: '',
      assume_quality: nil,
      category: nil
    }
    torrent_row = {
      name: 'Test Torrent',
      status: 2,
      tattributes: 'packed',
      identifiers: ['id'],
      identifier: 'legacy-id'
    }

    db = FakeDB.new
    def db.get_rows(table, conditions = nil)
      if table == 'torrents' && conditions == { status: 2 }
        [@row]
      else
        []
      end
    end
    db.instance_variable_set(:@row, torrent_row)

    Dir.mktmpdir do |tmp_dir|
      app = FakeApp.new(db: db, temp_dir: tmp_dir)
      service = MediaLibrarian::Services::TorrentQueueService.new(
        app: app,
        speaker: @speaker,
        client: FakeClient.new
      )

      captured_urls = []
      processed_paths = []

      Cache.stub(:object_unpack, ->(_value) { torrent_attributes }) do
        Cache.stub(:queue_state_add_or_update, nil) do
          TorrentSearch.stub(:get_tracker_config, ->(*_) { { 'no_download' => '0' } }) do
            TorrentSearch.stub(:get_torrent_file, ->(_tdid, url, *_rest, **) { captured_urls << url; 'downloaded.torrent' }) do
              service.stub(:process_download_request, ->(request) { processed_paths << request.path; true }) do
                service.parse_pending_downloads
              end
            end
          end
        end
      end

      assert_equal ['https://primary.example/download'], captured_urls
      assert_equal ['downloaded.torrent'], processed_paths
    end
  end

  def test_parse_pending_downloads_limits_items
    torrent_attributes = {
      link: '',
      tracker: 'tracker',
      magnet_link: '',
      files: [],
      move_completed: '',
      rename_main: '',
      queue: '',
      assume_quality: nil,
      category: nil
    }
    torrent_rows = Array.new(25) do |i|
      {
        name: "Test Torrent #{i}",
        status: 2,
        tattributes: 'packed',
        identifiers: ['id'],
        identifier: "legacy-id-#{i}"
      }
    end

    db = FakeDB.new
    def db.get_rows(table, conditions = nil)
      return @rows if table == 'torrents' && conditions == { status: 2 }

      []
    end
    db.instance_variable_set(:@rows, torrent_rows)

    app = FakeApp.new(db: db)
    service = MediaLibrarian::Services::TorrentQueueService.new(
      app: app,
      speaker: @speaker,
      client: FakeClient.new
    )

    processed = []
    Cache.stub(:object_unpack, ->(_value) { torrent_attributes }) do
      Cache.stub(:queue_state_add_or_update, nil) do
        TorrentSearch.stub(:get_tracker_config, ->(*_) { { 'no_download' => '1' } }) do
          service.stub(:process_download_request, ->(request) { processed << request.torrent_name; true }) do
            service.parse_pending_downloads(limit: 20)
          end
        end
      end
    end

    assert_equal 20, processed.length
  end
end

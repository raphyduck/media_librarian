# frozen_string_literal: true

require 'tmpdir'

require_relative 'service_test_helper'
require_relative '../../app/media_librarian/services'
require_relative '../../app/media_librarian/services/base_service'
require_relative '../../app/media_librarian/services/torrent_queue_service'

unless defined?(TorrentSearch)
  class TorrentSearch
    class << self
      def get_tracker_config(*)
        {}
      end

      def get_torrent_file(*)
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
            TorrentSearch.stub(:get_torrent_file, ->(_tdid, url) { captured_urls << url; 'downloaded.torrent' }) do
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
end

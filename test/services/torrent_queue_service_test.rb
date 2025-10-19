# frozen_string_literal: true

require_relative 'service_test_helper'
require_relative '../../app/services/media_librarian/services'
require_relative '../../app/services/media_librarian/services/base_service'
require_relative '../../app/services/media_librarian/services/torrent_queue_service'

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
    attr_accessor :db

    def initialize(db:)
      @db = db
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
end

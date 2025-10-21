# frozen_string_literal: true

require_relative 'service_test_helper'
require_relative '../../app/media_librarian/services'
require_relative '../../app/media_librarian/services/base_service'
require_relative '../../app/media_librarian/services/remote_sync_service'

class RemoteSyncServiceTest < Minitest::Test
  class FakeFileSystem
    attr_reader :md5_calls, :removed_paths

    def initialize
      @md5_calls = []
      @removed_paths = []
    end

    def directory?(_path)
      false
    end

    def search_folder(_path, _criteria)
      []
    end

    def md5sum(path)
      @md5_calls << path
      'abc123'
    end

    def rm_r(path)
      @removed_paths << path
    end

    def exist?(_path)
      true
    end
  end

  class FakeSSH
    def exec!(_command)
      yield(nil, :stdout, "abc123  file\n") if block_given?
    end
  end

  def setup
    @speaker = TestSupport::Fakes::Speaker.new
    @file_system = FakeFileSystem.new
    @service = MediaLibrarian::Services::RemoteSyncService.new(
      app: nil,
      speaker: @speaker,
      file_system: @file_system
    )
  end

  def test_compare_remote_files_handles_matching_hashes
    request = MediaLibrarian::Services::RemoteComparisonRequest.new(
      path: '/tmp/file',
      remote_server: 'remote',
      remote_user: 'user'
    )

    net_ssh = Module.new do
      def self.start(_server, _user, _opts = {})
        yield RemoteSyncServiceTest::FakeSSH.new
      end
    end

    unless defined?(Net)
      Object.const_set(:Net, Module.new)
      @net_defined = true
    end
    @original_ssh = Net.const_get(:SSH) if Net.const_defined?(:SSH)
    Net.const_set(:SSH, net_ssh)

    @service.compare_remote_files(request)

    assert_includes @speaker.messages, 'The 2 files are identical!'
  ensure
    Net.send(:remove_const, :SSH)
    Net.const_set(:SSH, @original_ssh) if @original_ssh
    Object.send(:remove_const, :Net) if @net_defined
  end
end

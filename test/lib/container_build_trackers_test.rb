# frozen_string_literal: true

require 'test_helper'
require 'fileutils'
require 'tmpdir'
require 'yaml'

module MediaLibrarian
  class ContainerBuildTrackersTest < Minitest::Test
    FakeApplication = Struct.new(:config_dir, :config_file, :config_example, :api_config_file, :env_flags, :tracker_dir, keyword_init: true)

    def setup
      @tmpdir = Dir.mktmpdir('container-trackers')
      @config_dir = File.join(@tmpdir, 'config')
      @tracker_dir = File.join(@tmpdir, 'trackers')
      FileUtils.mkdir_p(@config_dir)
      FileUtils.mkdir_p(@tracker_dir)
      @config_file = File.join(@config_dir, 'conf.yml')
      @config_example = File.join(@config_dir, 'conf.yml.example')
      File.write(@config_file, {}.to_yaml)
      File.write(@config_example, {}.to_yaml)
    end

    def teardown
      FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
    end

    def test_skips_placeholder_tracker_configs
      File.write(File.join(@tracker_dir, 'demo.yml'), { 'api_url' => 'torznab_api_url', 'api_key' => 'torznab_api_key' }.to_yaml)

      app = FakeApplication.new(config_dir: @config_dir,
                                config_file: @config_file,
                                config_example: @config_example,
                                api_config_file: File.join(@config_dir, 'api.yml'),
                                tracker_dir: @tracker_dir,
                                env_flags: {})

      speaker = TestSupport::Fakes::Speaker.new

      SimpleSpeaker::Speaker.stub(:new, speaker) do
        Storage::Db.stub(:new, Object.new) do
          container = Container.new(app)
          assert_empty container.trackers
        end
      end

      joined_messages = speaker.messages.join(' ')
      assert_includes joined_messages, 'demo'
      assert_includes joined_messages, 'api_url/api_key'
    end
  end
end

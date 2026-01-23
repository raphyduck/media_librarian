# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/video_utils'

class VideoUtilsTest < Minitest::Test
  def setup
    @speaker = TestSupport::Fakes::Speaker.new
    @environment = build_stubbed_environment(speaker: @speaker)
    @old_application = MediaLibrarian.application
    MediaLibrarian.application = @environment.application
  end

  def teardown
    MediaLibrarian.application = @old_application
    @environment.cleanup
  end

  def test_process_mkv_dry_run_logs_without_modifying_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'sample.mkv')
      File.write(path, 'original')

      result = VideoUtils.process_mkv(path, tool: 'mkvmerge', args: ['-o', path, path], dry_run: true)

      assert result[:success]
      messages = @speaker.messages.grep(String).join("\n")
      assert_includes messages, 'mkv temp dir:'
      assert_includes messages, 'dry_run: would lock'
      assert_equal 'original', File.read(path)
      refute File.exist?(File.join(dir, '.sample.mkv.lock'))
    end
  end

  def test_process_mkv_reports_missing_mkvmerge
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'missing.mkv')
      File.write(path, 'payload')

      with_env('PATH', '') do
        result = VideoUtils.process_mkv(path, tool: 'mkvmerge', args: ['-o', path, path])

        refute result[:success]
        assert_includes @speaker.messages, 'mkvmerge not available in PATH'
      end
    end
  end

  def test_process_mkv_pipeline_with_stubbed_mkvmerge
    # To generate a real MKV fixture for manual runs:
    # ffmpeg -f lavfi -i testsrc=size=128x72:rate=1 -t 1 -c:v libx264 test/fixtures/sample.mkv
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'fixture.mkv')
      File.write(path, 'original')
      mkvmerge_dir = File.join(dir, 'bin')
      FileUtils.mkdir_p(mkvmerge_dir)
      mkvmerge = File.join(mkvmerge_dir, 'mkvmerge')
      File.write(mkvmerge, "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, mkvmerge)

      with_env('PATH', "#{mkvmerge_dir}:#{ENV['PATH']}") do
        status = Struct.new(:success?).new(true)
        run_stub = lambda do |_tool, args, _timeout|
          out_index = args.index('-o') || args.index('--output')
          out_path = out_index ? args[out_index + 1] : args.first
          File.write(out_path, 'processed')
          ['ok', '', status]
        end

        result = VideoUtils.stub(:run_command, run_stub) do
          VideoUtils.stub(:mkv_validate_local, true) do
            VideoUtils.process_mkv(path, tool: 'mkvmerge', args: ['-o', path, path])
          end
        end

        assert result[:success]
        assert_equal 'processed', File.read(path)
        assert File.exist?("#{path}.bak")
      end
    end
  end

  private

  def with_env(key, value)
    old_value = ENV.fetch(key, nil)
    ENV[key] = value
    yield
  ensure
    ENV[key] = old_value
  end
end

# frozen_string_literal: true

require_relative 'service_test_helper'
require_relative '../../app/services/media_librarian/services'
require_relative '../../app/services/media_librarian/services/base_service'
require_relative '../../app/services/media_librarian/services/media_conversion_service'

class MediaConversionServiceTest < Minitest::Test
  class FakeFileSystem
    attr_reader :checked_paths

    def initialize
      @checked_paths = []
    end

    def exist?(_path)
      false
    end

    def directory?(_path)
      false
    end
  end

  def setup
    @speaker = TestSupport::Fakes::Speaker.new
    @file_system = FakeFileSystem.new
    @service = MediaLibrarian::Services::MediaConversionService.new(
      app: nil,
      speaker: @speaker,
      file_system: @file_system
    )
  end

  def test_reports_missing_path
    request = MediaLibrarian::Services::MediaConversionRequest.new(
      path: '/missing.flac',
      input_format: 'flac',
      output_format: 'mp3'
    )

    @service.convert(request)

    assert_includes @speaker.messages, '/missing.flac does not exist!'
  end

  def test_unknown_format_triggers_warning
    request = MediaLibrarian::Services::MediaConversionRequest.new(
      path: '/tmp/file.xxx',
      input_format: 'xxx',
      output_format: 'mp3'
    )

    @service.convert(request)

    assert_includes @speaker.messages, 'Unknown input format'
  end
end

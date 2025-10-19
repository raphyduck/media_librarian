# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../support/dependency_stubs'
require_relative '../support/container_helpers'
require_relative '../../lib/media_librarian/app_container_support'

unless defined?(EXTENSIONS_TYPE)
  EXTENSIONS_TYPE = {
    video: %w[mkv avi mp4],
    audio: %w[flac mp3]
  }.freeze
end

unless defined?(VALID_CONVERSION_INPUTS)
  VALID_CONVERSION_INPUTS = {
    video: %w[iso ts m2ts],
    audio: %w[flac]
  }.freeze
end

unless defined?(VALID_CONVERSION_OUTPUT)
  VALID_CONVERSION_OUTPUT = {
    video: %w[mkv],
    audio: %w[mp3]
  }.freeze
end

module ServiceTestHelper
  def build_service_environment
    TestSupport::ContainerHelpers::StubbedEnvironment.new
  end
end

Minitest::Test.include(ServiceTestHelper)

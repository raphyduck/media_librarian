# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../support/dependency_stubs'
require_relative '../support/container_helpers'
require_relative '../../lib/media_librarian/app_container_support'

unless defined?(EXTENSIONS_TYPE)
  EXTENSIONS_TYPE = {
    music: %w[flac mp3],
    video: %w[mkv avi mp4]
  }.freeze
end

unless defined?(VALID_CONVERSION_INPUTS)
  VALID_CONVERSION_INPUTS = {
    music: %w[flac],
    video: %w[iso ts m2ts]
  }.freeze
end

unless defined?(VALID_CONVERSION_OUTPUT)
  VALID_CONVERSION_OUTPUT = {
    music: %w[mp3],
    video: %w[mkv]
  }.freeze
end

module ServiceTestHelper
  def build_service_environment
    TestSupport::ContainerHelpers::StubbedEnvironment.new
  end
end

Minitest::Test.include(ServiceTestHelper)

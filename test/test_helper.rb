# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

# Never let the suite touch the real ~/.medialibrarian (live daemon socket,
# log, librarian.db): Dir.home, Application#config_dir and Daemon::SOCKET_PATH
# all derive from HOME. Must run before any application require below.
TEST_HOME = Dir.mktmpdir('ml-test-home')
ENV['HOME'] = TEST_HOME
Minitest.after_run { FileUtils.remove_entry(TEST_HOME) if Dir.exist?(TEST_HOME) }

require_relative '../lib/hash'
require_relative '../lib/array'
require_relative 'support/dependency_stubs'
require_relative '../librarian'
require_relative 'support/container_helpers'

module TestSupport
  module LibrarianState
    def reset_librarian_state!
      singleton = Librarian.singleton_class
      singleton.instance_variable_set(:@app, nil)
      singleton.instance_variable_set(:@command_registry, nil)
      Librarian.debug_classes = []
    end
  end
end

Minitest::Test.include(TestSupport::ContainerHelpers)
Minitest::Test.include(TestSupport::LibrarianState)

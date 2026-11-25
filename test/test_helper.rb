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
  # Each real MediaLibrarian::Application builds a Zeitwerk loader on app/,
  # lib/ and min_lib/; Zeitwerk allows one loader per directory per process.
  # Tests reset MediaLibrarian.application between cases, so a lazy rebuild
  # used to raise. Reuse the first real loader instead (production builds a
  # single Application, so this only exists in the test harness).
  module SharedZeitwerkLoader
    class << self
      attr_accessor :loader
    end

    private

    def setup_loader
      super
      SharedZeitwerkLoader.loader ||= @loader if @loader.is_a?(Zeitwerk::Loader)
    rescue Zeitwerk::Error => e
      shared = SharedZeitwerkLoader.loader
      raise unless shared && e.message.include?('already managed by')

      @loader.unregister if @loader.is_a?(Zeitwerk::Loader)
      @loader = shared
    end
  end
end
MediaLibrarian::Application.prepend(TestSupport::SharedZeitwerkLoader)

module TestSupport
  module Watchdog
    LIMIT = Integer(ENV.fetch('ML_TEST_STALL_SECONDS', '180'))
    @current = nil
    @started = nil
    class << self
      attr_accessor :current, :started
    end

    def run
      Watchdog.current = "#{self.class}##{name}"
      Watchdog.started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super
    ensure
      Watchdog.current = nil
    end
  end
end
Minitest::Test.prepend(TestSupport::Watchdog)
Thread.new do
  loop do
    sleep 5
    started = TestSupport::Watchdog.started
    next unless TestSupport::Watchdog.current && started
    next if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < TestSupport::Watchdog::LIMIT

    $stderr.puts "\n[watchdog] #{TestSupport::Watchdog.current} stalled > #{TestSupport::Watchdog::LIMIT}s"
    Thread.list.each do |t|
      $stderr.puts "[watchdog] thread #{t.name || t.object_id} #{t.status.inspect}\n  " + Array(t.backtrace).first(30).join("\n  ")
    end
    $stderr.flush
    exit!(3)
  end
end

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

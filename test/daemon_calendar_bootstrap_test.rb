# frozen_string_literal: true

require 'test_helper'
require_relative '../app/daemon'
require_relative '../app/calendar_feed'

class DaemonCalendarBootstrapTest < Minitest::Test
  def setup
    reset_librarian_state!
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
    Thread.current[:current_daemon] = :test_client
  end

  def teardown
    Thread.current[:current_daemon] = nil
    MediaLibrarian.application = nil
    cleanup_daemon_state
    @environment.cleanup if @environment
  end

  def test_bootstrap_refresh_runs_when_calendar_is_empty
    apply_calendar_config(refresh_on_start: true)
    attach_calendar_db(entry: nil)

    refreshes = 0
    CalendarFeed.stub(:refresh_feed, ->(*) { refreshes += 1 }) do
      Daemon.send(:bootstrap_calendar_feed_if_needed)
    end

    assert_equal 1, refreshes
  end

  def test_bootstrap_refresh_skipped_when_entries_exist
    apply_calendar_config(refresh_on_start: true)
    attach_calendar_db(entry: { id: 1 })

    CalendarFeed.stub(:refresh_feed, ->(*) { flunk('unexpected refresh') }) do
      Daemon.send(:bootstrap_calendar_feed_if_needed)
    end
  end

  def test_bootstrap_refresh_skipped_when_disabled
    apply_calendar_config(refresh_on_start: false)
    attach_calendar_db(entry: nil)

    CalendarFeed.stub(:refresh_feed, ->(*) { flunk('unexpected refresh') }) do
      Daemon.send(:bootstrap_calendar_feed_if_needed)
    end
  end

  private

  def apply_calendar_config(refresh_on_start: true)
    config = {
      'daemon' => { 'workers_pool_size' => 1, 'queue_slots' => 1 },
      'calendar' => {
        'refresh_every' => '12 hours',
        'refresh_on_start' => refresh_on_start,
        'refresh_days' => 10,
        'refresh_limit' => 25,
        'providers' => 'imdb|trakt'
      }
    }
    @environment.container.reload_config!(config)
  end

  def attach_calendar_db(entry: nil)
    dataset = FakeDataset.new(entry)
    database = FakeDatabase.new(dataset)
    db = FakeDb.new(database)
    @environment.application.define_singleton_method(:db) { db }
  end

  def cleanup_daemon_state
    %i[@running @template_cache @last_execution @queue_limits @calendar_refresh_mutex].each do |name|
      Daemon.instance_variable_set(name, nil)
    end
  end

  class FakeDb
    attr_reader :database

    def initialize(database)
      @database = database
    end

    def table_exists?(table)
      table.to_sym == :calendar_entries
    end
  end

  class FakeDatabase
    def initialize(dataset)
      @dataset = dataset
    end

    def [](_table)
      @dataset
    end
  end

  class FakeDataset
    def initialize(entry)
      @entry = entry
    end

    def first
      @entry
    end
  end
end

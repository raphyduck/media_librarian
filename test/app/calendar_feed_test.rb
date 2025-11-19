# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/calendar_feed'

class CalendarFeedTest < Minitest::Test
  def setup
    reset_librarian_state!
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
  end

  def teardown
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def test_refresh_feed_uses_calendar_configuration_defaults
    today = Date.new(2024, 1, 1)
    @environment.container.reload_config!(
      'daemon' => { 'workers_pool_size' => 1, 'queue_slots' => 1 },
      'calendar' => {
        'refresh_every' => '6 hours',
        'refresh_days' => 15,
        'refresh_limit' => 80,
        'providers' => 'imdb|tmdb'
      }
    )

    expected_range = today..(today + 15)
    calls = []
    service = Object.new
    service.define_singleton_method(:refresh) do |**kwargs|
      calls << kwargs
      []
    end

    CalendarFeed.stub(:calendar_service, service) do
      Date.stub(:today, today) do
        CalendarFeed.refresh_feed
      end
    end

    assert_equal 1, calls.length
    assert_equal({ date_range: expected_range, limit: 80, sources: %w[imdb tmdb] }, calls.first)
  end
end

# frozen_string_literal: true

require 'test_helper'
require 'date'
require 'net/http'
require_relative '../../lib/trakt_agent'

class TraktAgentTest < Minitest::Test
  def setup
    super
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
  end

  def teardown
    MediaLibrarian.application = nil
    @environment&.cleanup
    super
  end

  def test_calendar_entries_use_trakt_client_without_direct_http_calls
    start_date = Date.new(2024, 1, 1)
    days = 3

    calendar = Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def all_shows(start_date, days)
        @calls << [start_date, days]
        [:entries]
      end
    end.new

    fetcher = Class.new do
      attr_reader :calendar_called

      def initialize(calendar)
        @calendar = calendar
      end

      def calendar
        @calendar_called = true
        @calendar
      end
    end.new(calendar)

    @environment.application.trakt = fetcher

    Net::HTTP.stub(:start, ->(*) { flunk 'Net::HTTP.start should not be called' }) do
      result = TraktAgent.fetch_calendar_entries(:shows, start_date, days)
      assert_equal [:entries], result
    end

    assert fetcher.calendar_called
    assert_equal [[start_date, days]], calendar.calls
  end

  def test_calendar_entries_can_use_injected_fetcher
    start_date = Date.new(2024, 1, 1)
    days = 2

    calendar = Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def movies(start_date, days)
        @calls << [start_date, days]
        :from_calendar_method
      end
    end.new

    fetcher = Class.new do
      attr_reader :calendar_called

      def initialize(calendar)
        @calendar = calendar
      end

      def calendar
        @calendar_called = true
        @calendar
      end
    end.new(calendar)

    Net::HTTP.stub(:start, ->(*) { flunk 'Net::HTTP.start should not be called' }) do
      result = TraktAgent.fetch_calendar_entries(:movies, start_date, days, fetcher: fetcher)
      assert_equal :from_calendar_method, result
    end

    assert fetcher.calendar_called
    assert_equal [[start_date, days]], calendar.calls
  end
end

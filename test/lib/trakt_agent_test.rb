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

    calendars = Class.new do
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
      attr_reader :calendars_called

      def initialize(calendars)
        @calendars = calendars
      end

      def calendars
        @calendars_called = true
        @calendars
      end
    end.new(calendars)

    @environment.application.trakt = fetcher

    Net::HTTP.stub(:start, ->(*) { flunk 'Net::HTTP.start should not be called' }) do
      result = TraktAgent.fetch_calendar_entries(:shows, start_date, days)
      assert_equal [:entries], result
    end

    assert fetcher.calendars_called
    assert_equal [[start_date, days]], calendars.calls
  end

  def test_calendar_entries_can_use_injected_fetcher
    start_date = Date.new(2024, 1, 1)
    days = 2

    fetcher = Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def calendar(type:, start_date:, days:)
        @calls << [type, start_date, days]
        :from_calendar_method
      end
    end.new

    Net::HTTP.stub(:start, ->(*) { flunk 'Net::HTTP.start should not be called' }) do
      result = TraktAgent.fetch_calendar_entries(:movies, start_date, days, fetcher: fetcher)
      assert_equal :from_calendar_method, result
    end

    assert_equal [['movie', start_date, days]], fetcher.calls
  end
end

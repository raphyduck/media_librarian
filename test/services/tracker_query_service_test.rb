# frozen_string_literal: true

require_relative 'service_test_helper'
require_relative '../../app/services/media_librarian/services'
require_relative '../../app/services/media_librarian/services/base_service'
require_relative '../../app/services/media_librarian/services/tracker_query_service'

class TrackerQueryServiceTest < Minitest::Test
  class FakeApp
    attr_accessor :trackers, :config

    def initialize(trackers: {}, config: {})
      @trackers = trackers
      @config = config
    end
  end

  def setup
    @speaker = TestSupport::Fakes::Speaker.new
    @app = FakeApp.new
    @service = MediaLibrarian::Services::TrackerQueryService.new(
      app: @app,
      speaker: @speaker
    )
  end

  def test_parse_tracker_sources_handles_nested_structures
    sources = {
      'tracker_a' => {},
      'rss' => ['tracker_b', ['tracker_c']]
    }

    trackers = @service.parse_tracker_sources(sources)

    assert_includes trackers, 'tracker_a'
    assert_includes trackers, 'tracker_b'
    assert_includes trackers, 'tracker_c'
  end

  def test_get_trackers_defaults_to_registered_trackers
    trackers = { 'alpha' => Minitest::Mock.new }
    @app.trackers = trackers

    result = @service.get_trackers(nil)

    assert_equal ['alpha'], result
  end
end

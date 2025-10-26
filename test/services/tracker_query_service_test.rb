# frozen_string_literal: true

require 'ostruct'

require_relative 'service_test_helper'
require_relative '../../app/media_librarian/services'
require_relative '../../app/media_librarian/services/base_service'
require_relative '../../app/media_librarian/services/tracker_query_service'
require_relative '../../lib/media_librarian/application'
require_relative '../../lib/hash'
require_relative '../../lib/torznab_tracker'

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

  def test_torznab_tracker_uses_details_and_download_links
    caps = OpenStruct.new(
      search_modes: OpenStruct.new(
        search: OpenStruct.new(available: true),
        movie_search: OpenStruct.new(available: true),
        tv_search: OpenStruct.new(available: true)
      ),
      categories: [OpenStruct.new(name: 'Movies', id: '100')]
    )

    xml = <<~XML
      <rss>
        <channel>
          <item>
            <title>Example One</title>
            <size>123</size>
            <link>https://tracker.example/details/1</link>
            <guid>https://tracker.example/download/1</guid>
            <enclosure url="https://tracker.example/enclosure/1" />
            <attr name="seeders" value="10" />
            <attr name="leechers" value="2" />
          </item>
          <item>
            <title>Example Two</title>
            <size>456</size>
            <link>https://tracker.example/details/2</link>
            <guid>https://tracker.example/download/2</guid>
            <attr name="seeders" value="5" />
            <attr name="leechers" value="1" />
          </item>
        </channel>
      </rss>
    XML

    fake_client = Struct.new(:caps, :xml) do
      def get(_params)
        xml
      end
    end.new(caps, xml)

    environment = build_service_environment
    app_defined = MediaLibrarian.instance_variable_defined?(:@application)
    old_application = MediaLibrarian.instance_variable_get(:@application) if app_defined
    MediaLibrarian.application = environment.application

    Torznab::Client.stub(:new, ->(*) { fake_client }) do
      tracker = TorznabTracker.new({ 'api_url' => 'api', 'api_key' => 'key' }, 'test')
      results = tracker.search('movies', 'query')

      first, second = results
      assert_equal 'https://tracker.example/details/1', first[:link]
      assert_equal 'https://tracker.example/enclosure/1', first[:torrent_link]
      assert_equal 'https://tracker.example/details/2', second[:link]
      assert_equal 'https://tracker.example/download/2', second[:torrent_link]
    end
  ensure
    if app_defined
      MediaLibrarian.application = old_application
    elsif MediaLibrarian.instance_variable_defined?(:@application)
      MediaLibrarian.remove_instance_variable(:@application)
    end
    environment&.cleanup
  end
end

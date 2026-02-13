# frozen_string_literal: true

require 'ostruct'
require 'uri'
require 'yaml'
require 'fileutils'
require 'tmpdir'

require_relative 'service_test_helper'
require_relative '../../app/media_librarian/services'
require_relative '../../app/media_librarian/services/base_service'
require_relative '../../app/media_librarian/services/tracker_query_service'
require_relative '../../lib/media_librarian/application'
require_relative '../../lib/hash'
require_relative '../../lib/torznab_tracker'

unless defined?(TorrentRss)
  class TorrentRss
    def self.links(*, **)
      []
    end
  end
end

class TrackerQueryServiceTest < Minitest::Test
  FakeMechanizePage = Struct.new(:uri, :body_content, keyword_init: true) do
    attr_reader :saved_paths

    def initialize(**kwargs)
      super
      self.uri = URI(uri) if uri.is_a?(String)
      @saved_paths = []
      @body_content ||= 'torrent-data'
    end

    def body
      body_content
    end

    def save(path)
      @saved_paths << path
      File.write(path, body_content)
    end
  end

  class FakeAgent
    attr_reader :requested_urls

    def initialize(response)
      @responses = response.is_a?(Array) ? response.dup : [response]
      @requested_urls = []
    end

    def get(url)
      @requested_urls << url
      next_response = @responses.shift || @responses.last
      raise next_response if next_response.is_a?(Exception)

      next_response
    end
  end
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

  def test_parse_tracker_sources_records_rss_tracker_identifier
    feed_url = 'https://secure.example/rss'
    sources = {
      'rss' => [
        { feed_url => { 'tracker' => 'secure' } }
      ]
    }

    trackers = @service.parse_tracker_sources(sources)

    assert_includes trackers, feed_url
    lookup = @service.instance_variable_get(:@rss_tracker_lookup)
    assert_equal 'secure', lookup[feed_url]
  end

  def test_get_trackers_defaults_to_registered_trackers
    trackers = { 'alpha' => Minitest::Mock.new }
    @app.trackers = trackers

    result = @service.get_trackers(nil)

    assert_equal ['alpha'], result
  end

  def test_launch_search_uses_rss_tracker_identifier
    feed_url = 'https://secure.example/rss'
    sources = {
      'rss' => [
        { feed_url => { 'tracker' => 'secure' } }
      ]
    }

    @service.parse_tracker_sources(sources)

    TorrentRss.stub(:links, ->(url, *_args, tracker: nil) {
      assert_equal feed_url, url
      assert_equal 'secure', tracker
      []
    }) do
      @service.launch_search(feed_url, 'movies', 'keyword')
    end
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
          <item>
            <title>Example Three</title>
            <size>789</size>
            <link>https://tracker.example/dl/3</link>
            <comments>https://tracker.example/details/3</comments>
            <guid>https://tracker.example/dl/3</guid>
            <attr name="seeders" value="8" />
            <attr name="leechers" value="0" />
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

      first, second, third = results
      assert_equal 'https://tracker.example/enclosure/1', first[:link]
      assert_equal 'https://tracker.example/details/1', first[:torrent_link]
      assert_equal 'https://tracker.example/download/2', second[:link]
      assert_equal 'https://tracker.example/details/2', second[:torrent_link]
      assert_equal 'https://tracker.example/dl/3', third[:link]
      assert_equal 'https://tracker.example/details/3', third[:torrent_link]
      assert_equal '10', first[:seeders]
      assert_equal '2', first[:leechers]
      assert_equal '5', second[:seeders]
      assert_equal '1', second[:leechers]
      assert_equal '8', third[:seeders]
      assert_equal '0', third[:leechers]
    end
  ensure
    if app_defined
      MediaLibrarian.application = old_application
    elsif MediaLibrarian.instance_variable_defined?(:@application)
      MediaLibrarian.remove_instance_variable(:@application)
    end
    environment&.cleanup
  end

  def test_torznab_tracker_prefers_comments_for_details_links
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
            <title>Example</title>
            <size>123</size>
            <link>https://jackett.example/dl/1</link>
            <guid>https://tracker.example/download/1</guid>
            <attr name="seeders" value="10" />
            <attr name="leechers" value="2" />
          </item>
          <item>
            <title>Placeholder</title>
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

      assert_equal 'https://tracker.example/download/1', results.first[:link]
    end
  ensure
    if app_defined
      MediaLibrarian.application = old_application
    elsif MediaLibrarian.instance_variable_defined?(:@application)
      MediaLibrarian.remove_instance_variable(:@application)
    end
    environment&.cleanup
  end

  def test_torznab_tracker_handles_single_item_response
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
            <title>Daddy Nostalgie</title>
            <size>700000000</size>
            <link>https://tracker.example/details/1</link>
            <guid>https://tracker.example/download/1</guid>
            <enclosure url="https://tracker.example/enclosure/1" />
            <attr name="seeders" value="3" />
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
      results = tracker.search('movies', 'Daddy Nostalgie')

      assert_equal 1, results.length
      assert_equal 'Daddy Nostalgie', results.first[:name]
      assert_equal 'https://tracker.example/enclosure/1', results.first[:link]
      assert_equal 'https://tracker.example/details/1', results.first[:torrent_link]
      assert_equal '3', results.first[:seeders]
      assert_equal '1', results.first[:leechers]
    end
  ensure
    if app_defined
      MediaLibrarian.application = old_application
    elsif MediaLibrarian.instance_variable_defined?(:@application)
      MediaLibrarian.remove_instance_variable(:@application)
    end
    environment&.cleanup
  end

  def test_get_results_strips_special_characters_from_keyword
    searched_keywords = []
    fake_tracker = Object.new
    fake_tracker.define_singleton_method(:search) do |_category, keyword|
      searched_keywords << keyword
      []
    end
    @app.trackers = { 'test_tracker' => fake_tracker }

    request = MediaLibrarian::Services::TrackerSearchRequest.new(
      sources: 'test_tracker',
      keyword: "Now You See Me: Now You Don't (2025)",
      category: 'movies'
    )
    @service.get_results(request)

    assert searched_keywords.any? { |kw| kw.include?("Now You See Me Now You Dont 2025") },
           "Expected keyword without special characters, got: #{searched_keywords.inspect}"
    searched_keywords.each do |kw|
      refute_match(/['\(\)\:!\?;,"]/, kw, "Keyword should not contain special characters: #{kw}")
    end
  end

  def test_get_results_strips_exclamation_and_question_marks
    searched_keywords = []
    fake_tracker = Object.new
    fake_tracker.define_singleton_method(:search) do |_category, keyword|
      searched_keywords << keyword
      []
    end
    @app.trackers = { 'test_tracker' => fake_tracker }

    request = MediaLibrarian::Services::TrackerSearchRequest.new(
      sources: 'test_tracker',
      keyword: "What?! Is This Real!",
      category: 'movies'
    )
    @service.get_results(request)

    assert searched_keywords.any? { |kw| kw.include?("What Is This Real") },
           "Expected keyword without ! and ?, got: #{searched_keywords.inspect}"
  end

  def test_get_torrent_file_uses_tracker_session_when_metadata_exists
    environment = build_service_environment
    app_defined = MediaLibrarian.instance_variable_defined?(:@application)
    old_application = MediaLibrarian.application if app_defined
    MediaLibrarian.application = environment.application

    app = environment.application
    tracker = 'secure'
    metadata_path = File.join(app.tracker_dir, "#{tracker}.login.yml")
    File.write(metadata_path, { 'login_url' => 'https://tracker.example/login' }.to_yaml)
    ensure_mechanizer_accessor(app)
    app.mechanizer = Minitest::Mock.new

    page = FakeMechanizePage.new(uri: 'https://tracker.example/file.torrent')
    agent = FakeAgent.new(page)
    login_service = Minitest::Mock.new
    login_service.expect(:ensure_session, agent, [tracker])

    destination = Dir.mktmpdir('tracker-query-test')
    service = MediaLibrarian::Services::TrackerQueryService.new(app: app, speaker: @speaker)
    path = service.stub(:tracker_login_service, login_service) do
      service.get_torrent_file('123', 'https://tracker.example/file.torrent', destination, tracker: tracker)
    end

    assert File.exist?(path)
    assert_equal ['https://tracker.example/file.torrent'], agent.requested_urls
    login_service.verify
  ensure
    FileUtils.rm_f(path) if path && File.exist?(path)
    FileUtils.remove_entry(destination) if defined?(destination) && destination
    restore_application(environment, old_application, app_defined)
  end

  def test_get_torrent_file_reauthenticates_when_redirected_to_login
    environment = build_service_environment
    app_defined = MediaLibrarian.instance_variable_defined?(:@application)
    old_application = MediaLibrarian.application if app_defined
    MediaLibrarian.application = environment.application

    app = environment.application
    tracker = 'secure'
    metadata_path = File.join(app.tracker_dir, "#{tracker}.login.yml")
    File.write(metadata_path, { 'login_url' => 'https://tracker.example/login' }.to_yaml)
    ensure_mechanizer_accessor(app)
    app.mechanizer = Minitest::Mock.new

    login_page = FakeMechanizePage.new(uri: 'https://tracker.example/login')
    download_page = FakeMechanizePage.new(uri: 'https://tracker.example/file.torrent')
    login_agent = FakeAgent.new(login_page)
    authed_agent = FakeAgent.new(download_page)

    login_service = Minitest::Mock.new
    login_service.expect(:ensure_session, login_agent, [tracker])
    login_service.expect(:login, authed_agent, [tracker])

    destination = Dir.mktmpdir('tracker-query-test')
    service = MediaLibrarian::Services::TrackerQueryService.new(app: app, speaker: @speaker)
    path = service.stub(:tracker_login_service, login_service) do
      service.get_torrent_file('123', 'https://tracker.example/file.torrent', destination, tracker: tracker)
    end

    assert File.exist?(path)
    assert_equal ['https://tracker.example/file.torrent'], login_agent.requested_urls
    assert_equal ['https://tracker.example/file.torrent'], authed_agent.requested_urls
    login_service.verify
  ensure
    FileUtils.rm_f(path) if path && File.exist?(path)
    FileUtils.remove_entry(destination) if defined?(destination) && destination
    restore_application(environment, old_application, app_defined)
  end

end

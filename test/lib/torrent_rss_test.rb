# frozen_string_literal: true

require 'yaml'
require 'ostruct'
require 'bigdecimal/util'

require_relative '../services/service_test_helper'
require_relative '../../lib/media_librarian/application'
require_relative '../../init/global'
require_relative '../../lib/torrent_rss'

module Feedjira
  class << self
    attr_accessor :parsed_bodies
  end
  def self.parse(*)
    raise 'stub'
  end
end unless defined?(Feedjira)

class TorrentRssTest < Minitest::Test
  FEED_URL = 'https://feed.example/rss'

  def setup
    @speaker = TestSupport::Fakes::Speaker.new
  end

  def test_links_uses_tracker_session_when_metadata_exists
    environment, app, tracker, old_application, app_defined = prepare_application
    metadata_path = File.join(app.tracker_dir, "#{tracker}.login.yml")
    File.write(metadata_path, { 'login_url' => 'https://tracker.example/login' }.to_yaml)

    response = Struct.new(:body).new('<rss></rss>')
    agent = Minitest::Mock.new
    agent.expect(:get, response, [FEED_URL])
    login_service = Minitest::Mock.new
    login_service.expect(:ensure_session, agent, [tracker])

    entries = [build_entry]
    results = verify_links(entries) do
      TorrentRss.stub(:tracker_login_service, login_service) do
        TorrentRss.links(FEED_URL, tracker: tracker)
      end
    end
    login_service.verify
    agent.verify
    assert_equal 1, results.size
  ensure
    restore_application(environment, old_application, app_defined)
  end

  def test_links_use_global_agent_without_metadata
    environment, app, tracker, old_application, app_defined = prepare_application
    response = Struct.new(:body).new('<rss></rss>')
    global_agent = Minitest::Mock.new
    global_agent.expect(:get, response, [FEED_URL])
    app.mechanizer = global_agent

    entries = [build_entry]
    results = verify_links(entries) do
      TorrentRss.links(FEED_URL, tracker: tracker)
    end
    global_agent.verify
    assert_equal 1, results.size
  ensure
    restore_application(environment, old_application, app_defined)
  end

  private

  def prepare_application
    environment = build_service_environment
    app = environment.application
    ensure_mechanizer_accessor(app)
    app_defined = MediaLibrarian.instance_variable_defined?(:@application)
    old_application = MediaLibrarian.application if app_defined
    MediaLibrarian.application = app
    tracker = 'secure'
    [environment, app, tracker, old_application, app_defined]
  end

  def verify_links(entries)
    Feedjira.stub(:parse, ->(_body) { Struct.new(:entries).new(entries) }) do
      yield
    end
  end

  def build_entry
    OpenStruct.new(
      summary: String.new('Size: 1 MB Seeders: 5 Leechers: 0'),
      title: String.new('Example Torrent'),
      image: String.new('magnet:?xt=urn:btih:ABC'),
      entry_id: String.new('magnet:?xt=urn:btih:ABC'),
      url: String.new('magnet:?xt=urn:btih:ABC'),
      published: Time.now
    )
  end

end

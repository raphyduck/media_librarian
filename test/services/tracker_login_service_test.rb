# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'uri'
require 'selenium-webdriver'

require_relative 'service_test_helper'
require_relative '../../app/media_librarian/services/base_service'
require_relative '../../app/media_librarian/services/tracker_login_service'

module MediaLibrarian
  module Services
    class TrackerLoginServiceTest < Minitest::Test
      def setup
        @tmp_dir = Dir.mktmpdir('tracker-login-test')
        @tracker_dir = File.join(@tmp_dir, 'trackers')
        FileUtils.mkdir_p(@tracker_dir)
      end

      def teardown
        FileUtils.remove_entry(@tmp_dir) if @tmp_dir && Dir.exist?(@tmp_dir)
      end

      def test_browser_login_captures_cookies_and_persists_session
        tracker_name = 'example'
        metadata = {
          'login_url' => 'https://example.com/login',
          'browser_login' => true,
          'browser_driver' => 'firefox'
        }
        File.write(File.join(@tracker_dir, "#{tracker_name}.login.yml"), metadata.to_yaml)

        app = Struct.new(:tracker_dir, :tracker_client, :tracker_client_last_login)
                    .new(@tracker_dir, {}, {})
        speaker = Minitest::Mock.new
        prompt = 'Press enter once the browser login is complete.'
        speaker.expect(:ask_if_needed, nil, [prompt, 0])

        agent = Mechanize.new
        cookie = {
          name: 'session_id',
          value: 'abc123',
          domain: 'example.com',
          path: '/',
          expires: Time.now + 3600,
          secure: true,
          httpOnly: true
        }
        driver = FakeDriver.new(cookies: [cookie], current_url: 'https://example.com/account')

        Mechanize.stub(:new, agent) do
          Selenium::WebDriver.stub(:for, ->(_) { driver }) do
            service = TrackerLoginService.new(app: app, speaker: speaker)
            result = service.login(tracker_name)

            assert_same agent, result
            assert_same agent, app.tracker_client[tracker_name]
          end
        end

        speaker.verify
        assert driver.quit_called
        assert_equal 'https://example.com/login', driver.visited_url

        cookie_path = File.join(@tracker_dir, 'example.cookies')
        assert File.exist?(cookie_path)

        stored_cookies = agent.cookie_jar.cookies(URI('https://example.com/'))
        assert_equal ['session_id'], stored_cookies.map(&:name)
        assert_equal ['abc123'], stored_cookies.map(&:value)
        assert_in_delta(Time.now + 3600, stored_cookies.first.expires, 5)

        refute_nil app.tracker_client_last_login[tracker_name]
      end

      class FakeDriver
        attr_reader :visited_url

        def initialize(cookies:, current_url:)
          @cookies = cookies
          @current_url = current_url
          @quit_called = false
        end

        def navigate
          Navigate.new(self)
        end

        def current_url
          @current_url
        end

        def manage
          Manage.new(@cookies)
        end

        def quit
          @quit_called = true
        end

        def quit_called
          @quit_called
        end

        def register_visit(url)
          @visited_url = url
        end

        class Navigate
          def initialize(driver)
            @driver = driver
          end

          def to(url)
            @driver.register_visit(url)
          end
        end

        class Manage
          def initialize(cookies)
            @cookies = cookies
          end

          def all_cookies
            @cookies
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require 'yaml'
require 'mechanize'
require 'fileutils'
require 'uri'

module MediaLibrarian
  module Services
    class TrackerLoginService < BaseService
      AuthenticationError = Class.new(StandardError)

      def login(tracker_name, no_prompt: 0)
        metadata = load_metadata(tracker_name)
        return browser_login(tracker_name, metadata, no_prompt) if metadata['browser_login']

        agent = build_agent(metadata)
        load_cookies(agent, tracker_name)
        page = agent.get(metadata.fetch('login_url'))
        form = resolve_form(page, metadata)
        credentials = collect_credentials(tracker_name, metadata, no_prompt)
        apply_fields(form, credentials, metadata)
        result = submit_form(form, metadata)
        raise AuthenticationError, "Failed to authenticate with #{tracker_name}" unless authenticated?(result, metadata)

        cache_session(tracker_name, agent)
        persist_cookies(agent, tracker_name)
        agent
      end

      def ensure_session(tracker_name, no_prompt: 0)
        cached = app.tracker_client[tracker_name]
        return cached if cached

        metadata = load_metadata(tracker_name)
        agent = build_agent(metadata)
        if load_cookies(agent, tracker_name)
          cache_session(tracker_name, agent)
          agent
        else
          login(tracker_name, no_prompt: no_prompt)
        end
      end

      private

      def load_metadata(tracker_name)
        path = File.join(app.tracker_dir, "#{tracker_name}.login.yml")
        raise ArgumentError, "Missing login metadata for #{tracker_name}" unless File.exist?(path)

        YAML.safe_load(File.read(path), aliases: true) || {}
      end

      def browser_login(tracker_name, metadata, no_prompt)
        agent = build_agent(metadata)
        require 'selenium-webdriver'

        driver = nil
        driver = Selenium::WebDriver.for((metadata['browser_driver'] || 'firefox').to_sym)
        begin
          no_prompt = no_prompt.to_i
          driver.navigate.to(metadata.fetch('login_url'))
          speaker.ask_if_needed('Press enter once the browser login is complete.', no_prompt)
          merge_browser_cookies(driver, agent, metadata)
        ensure
          driver.quit if driver
        end

        cache_session(tracker_name, agent)
        persist_cookies(agent, tracker_name)
        agent
      end

      def build_agent(metadata)
        Mechanize.new.tap do |agent|
          agent.user_agent_alias = metadata['user_agent_alias'] if metadata['user_agent_alias']
          agent.user_agent = metadata['user_agent'] if metadata['user_agent']
        end
      end

      def resolve_form(page, metadata)
        selector = metadata['form_selector']
        form_name = metadata['form_name']
        form = if selector
                 page.form_with(css: selector)
               elsif form_name
                 page.form_with(name: form_name)
               else
                 page.forms.first
               end
        raise ArgumentError, 'Login form not found' unless form

        form
      end

      def collect_credentials(tracker_name, metadata, no_prompt)
        no_prompt = no_prompt.to_i
        prompts = metadata['prompts'] || {}
        defaults = metadata['defaults'] || {}
        stored = metadata['credentials'] || {}

        %w[username password].each_with_object({}) do |field, memo|
          prompt = prompts[field] || default_prompt(field, tracker_name)
          memo[field] = fetch_value(stored[field], prompt, no_prompt, defaults[field])
        end
      end

      def fetch_value(existing, prompt, no_prompt, default)
        return existing unless blank?(existing)

        value = speaker.ask_if_needed(prompt, no_prompt, default)
        value = default if blank?(value) && !blank?(default)
        raise ArgumentError, prompt if blank?(value)

        value
      end

      def apply_fields(form, credentials, metadata)
        form[metadata.fetch('username_field')] = credentials.fetch('username')
        form[metadata.fetch('password_field')] = credentials.fetch('password')

        extra_fields(metadata).each { |name, value| form[name] = value }
        checkbox_options(metadata).each { |name, checked| set_checkbox(form, name, checked) }
      end

      def set_checkbox(form, name, checked)
        box = form.checkbox_with(name: name) || form.checkbox_with(id: name)
        return unless box

        checked ? box.check : box.uncheck
      end

      def submit_form(form, metadata)
        button_config = metadata['submit_button']
        return form.submit unless button_config

        button = find_button(form, button_config)
        raise ArgumentError, 'Submit button not found' unless button

        form.submit(button)
      end

      def find_button(form, config)
        return form.button_with(symbolize_keys(config)) if config.is_a?(Hash)

        form.button_with(name: config) || form.button_with(value: config)
      end

      def authenticated?(page, metadata)
        success = false
        success ||= page.uri.to_s.match?(Regexp.new(metadata['success_url_match'])) if metadata['success_url_match'] && page.uri
        success ||= page.at(metadata['success_selector']) if metadata['success_selector']
        success ||= page.body.include?(metadata['success_match']) if metadata['success_match']
        success || (!metadata['success_url_match'] && !metadata['success_selector'] && !metadata['success_match'])
      end

      def cache_session(tracker_name, agent)
        app.tracker_client[tracker_name] = agent
        app.tracker_client_last_login[tracker_name] = Time.now
      end

      def persist_cookies(agent, tracker_name)
        FileUtils.mkdir_p(app.tracker_dir)
        agent.cookie_jar.save(cookie_path(tracker_name))
      end

      def merge_browser_cookies(driver, agent, metadata)
        target_uri = begin
          uri = URI(driver.current_url)
          uri = URI(metadata.fetch('login_url')) unless uri.host
          uri
        rescue URI::InvalidURIError
          URI(metadata.fetch('login_url'))
        end

        driver.manage.all_cookies.each do |cookie|
          name = cookie[:name] || cookie['name']
          value = cookie[:value] || cookie['value']
          next if blank?(name)

          mechanize_cookie = Mechanize::Cookie.new(name, value)
          mechanize_cookie.domain = cookie[:domain] || cookie['domain'] || target_uri.host
          mechanize_cookie.path = cookie[:path] || cookie['path'] || '/'
          expires = cookie[:expires] || cookie['expires']
          mechanize_cookie.expires = expires.is_a?(Numeric) ? Time.at(expires) : expires if expires
          mechanize_cookie.secure = cookie[:secure] || cookie['secure'] || false
          http_only = cookie[:httpOnly] || cookie['httpOnly'] || false
          mechanize_cookie.instance_variable_set(:@httponly, http_only)
          agent.cookie_jar.add(target_uri, mechanize_cookie)
        end
      end

      def load_cookies(agent, tracker_name)
        path = cookie_path(tracker_name)
        return false unless File.exist?(path)

        agent.cookie_jar.load(path)
        true
      end

      def cookie_path(tracker_name)
        File.join(app.tracker_dir, "#{tracker_name}.cookies")
      end

      def blank?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end

      def extra_fields(metadata)
        case metadata['fields']
        when Array
          metadata['fields'].each_with_object({}) do |entry, memo|
            entry.each { |name, value| memo[name] = value }
          end
        when Hash
          metadata['fields']
        else
          {}
        end
      end

      def checkbox_options(metadata)
        Array(metadata['checkboxes']).flat_map do |entry|
          entry.is_a?(Hash) ? entry.to_a : [[entry, true]]
        end
      end

      def symbolize_keys(hash)
        hash.each_with_object({}) { |(key, value), memo| memo[key.to_sym] = value }
      end

      def default_prompt(field, tracker_name)
        "Enter #{field} for #{tracker_name}:"
      end
    end
  end
end

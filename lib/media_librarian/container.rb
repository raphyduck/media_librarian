# frozen_string_literal: true

require 'yaml'
require 'net/http'

require 'io/console'

require_relative '../simple_speaker'
require_relative '../simple_args_dispatch' unless defined?(SimpleArgsDispatch)
require_relative '../logger'

require_relative '../storage/db' unless defined?(Storage::Db)
require_relative '../torznab_tracker' unless defined?(TorznabTracker)
require_relative '../utils' unless defined?(Utils)

module MediaLibrarian
  # Container responsible for managing application wide service instances.
  # All services are instantiated once during boot and reused everywhere.
  # Hash based structures are deep frozen to protect against accidental
  # mutation while shared objects that need to keep mutable state remain
  # unfrozen.
  class Container
    attr_reader :application

    def initialize(application)
      @application = application
      @services = {}
      bootstrap!
    end

    def config
      services.fetch(:config)
    end

    def speaker
      services.fetch(:speaker)
    end

    def speaker=(value)
      store(:speaker, value, freeze: false)
      store(:args_dispatch, SimpleArgsDispatch::Agent.new(speaker, application.env_flags), freeze: false)
      speaker
    end

    def args_dispatch
      services.fetch(:args_dispatch)
    end

    def db
      services.fetch(:db)
    end

    def db=(value)
      store(:db, value, freeze: false)
    end

    def trackers
      services.fetch(:trackers)
    end

    def trackers=(value)
      store(:trackers, value)
    end

    def str_closeness
      services.fetch(:str_closeness)
    end

    def str_closeness=(value)
      store(:str_closeness, value, freeze: false)
    end

    def tracker_client
      services.fetch(:tracker_client)
    end

    def tracker_client=(value)
      store(:tracker_client, value, freeze: false)
    end

    def tracker_client_last_login
      services.fetch(:tracker_client_last_login)
    end

    def tracker_client_last_login=(value)
      store(:tracker_client_last_login, value, freeze: false)
    end

    def api_option
      services.fetch(:api_option)
    end

    def api_option=(value)
      update_api_option(value)
    end

    def workers_pool_size
      services.fetch(:workers_pool_size)
    end

    def queue_slots
      services.fetch(:queue_slots)
    end

    def finished_jobs_per_queue
      services.fetch(:finished_jobs_per_queue)
    end

    def reload_api_option!
      update_api_option(load_api_option_from_config)
    end

    def reload_config!(new_settings)
      store(:config, new_settings)

      daemon_config = config.fetch('daemon', {}) || {}
      store(:workers_pool_size, daemon_config['workers_pool_size'] || 4, freeze: true)
      store(:queue_slots, daemon_config['queue_slots'] || 4, freeze: true) # retained for backwards compatibility
      store(:finished_jobs_per_queue, normalized_finished_jobs_limit(daemon_config), freeze: true)

      store(:trackers, build_trackers)

      reload_api_option!
    end

    private

    attr_reader :services

    def bootstrap!
      store(:config, SimpleConfigMan.load_settings(application.config_dir,
                                                  application.config_file,
                                                  application.config_example))

      log_dir = File.join(application.config_dir, 'log')
      log_path, error_log_path = Logger.log_paths(log_dir)
      store(:speaker, SimpleSpeaker::Speaker.new(log_path, error_log_path), freeze: false)
      store(:args_dispatch, SimpleArgsDispatch::Agent.new(speaker, application.env_flags), freeze: false)

      store(:db, Storage::Db.new(File.join(application.config_dir, 'librarian.db')), freeze: false)

      store(:trackers, build_trackers)

      store(:str_closeness, FuzzyStringMatch::JaroWinkler.create(:pure), freeze: false)
      store(:tracker_client, {}, freeze: false)
      store(:tracker_client_last_login, {}, freeze: false)

      reload_api_option!

      daemon_config = config.fetch('daemon', {}) || {}
      store(:workers_pool_size, daemon_config['workers_pool_size'] || 4, freeze: true)
      store(:queue_slots, daemon_config['queue_slots'] || 4, freeze: true) # retained for backwards compatibility
      store(:finished_jobs_per_queue, normalized_finished_jobs_limit(daemon_config), freeze: true)
    end

    def build_trackers
      tracker_configs.each_with_object({}) do |(tracker_name, opts), memo|
        api_url = opts['api_url']
        api_key = opts['api_key']
        url_template = opts['url_template']
        if [api_url, api_key, url_template].any? { |value| placeholder_value?(value) }
          speaker.speak_up("Skipping tracker '#{tracker_name}': update trackers/#{tracker_name}.yml placeholders.") if speaker.respond_to?(:speak_up)
          next
        end

        memo[tracker_name] = TorznabTracker.new(opts, tracker_name)
      rescue Torznab::Errors::XmlError
        if speaker.respond_to?(:speak_up)
          body, body_prefix = fetch_caps_diagnostic(api_url)
          error = Hash.from_xml(body) || {}
          error = error.dig(:caps, :error) || error[:error] || {}
          code = error.is_a?(Hash) ? error[:code] : nil
          description = error.is_a?(Hash) ? error[:description] : nil
          speaker.speak_up("Tracker caps XML error: name=#{tracker_name} file=trackers/#{tracker_name}.yml code=#{code.inspect} description=#{description.inspect} body_prefix=#{body_prefix.inspect}")
        end
      rescue StandardError => e
        if speaker.respond_to?(:speak_up)
          api_key_present = !api_key.to_s.empty?
          speaker.speak_up("Tracker config error: name=#{tracker_name} file=trackers/#{tracker_name}.yml api_url=#{api_url.inspect} url_template=#{url_template.inspect} api_key_present=#{api_key_present}")
        end
        if speaker.respond_to?(:tell_error)
          args = begin
            Utils.arguments_dump(binding)
          rescue StandardError
            nil
          end
          speaker.tell_error(e, args)
        end
      end
    end

    DEFAULT_API_OPTION = {
      'bind_address' => '127.0.0.1',
      'listen_port' => 8888,
      'auth' => {},
      'ssl_enabled' => false,
      'ssl_certificate_path' => nil,
      'ssl_private_key_path' => nil,
      'ssl_ca_path' => nil,
      'ssl_verify_mode' => 'none',
      'ssl_client_verify_mode' => 'none'
    }.freeze

    DEFAULT_FINISHED_JOBS_PER_QUEUE = 100

    def default_api_option
      deep_dup(DEFAULT_API_OPTION)
    end

    def tracker_configs
      return {} unless File.directory?(application.tracker_dir)

      Dir.each_child(application.tracker_dir).each_with_object({}) do |tracker, memo|
        file_path = File.join(application.tracker_dir, tracker)
        next unless File.file?(file_path) && tracker.end_with?('.yml')

        opts = YAML.safe_load(File.read(file_path), aliases: true) || {}
        next unless opts.is_a?(Hash)

        tracker_name = tracker.sub(/\.yml$/, '')
        memo[tracker_name] = opts
      rescue StandardError => e
        speaker.tell_error(e, Utils.arguments_dump(binding)) if speaker.respond_to?(:tell_error)
      end
    end

    def load_api_option_from_config
      config_path = application.api_config_file
      return {} unless config_path && File.exist?(config_path)

      loaded = YAML.safe_load(File.read(config_path), aliases: true)
      return {} unless loaded.is_a?(Hash)

      stringify_keys(loaded)
    rescue StandardError => e
      speaker.tell_error(e, Utils.arguments_dump(binding)) if speaker.respond_to?(:tell_error)
      {}
    end

    def update_api_option(overrides)
      overrides = stringify_keys(overrides) if overrides.is_a?(Hash)
      merged = merge_api_options(default_api_option, overrides)
      store(:api_option, merged)
    end

    def merge_api_options(defaults, overrides)
      return defaults if overrides.nil?

      overrides.each_with_object(deep_dup(defaults)) do |(key, value), memo|
        if memo[key].is_a?(Hash) && value.is_a?(Hash)
          memo[key] = memo[key].merge(value)
        else
          memo[key] = value
        end
      end
    end

    def normalized_finished_jobs_limit(daemon_config)
      limit = daemon_config['finished_jobs_per_queue']
      limit = limit.to_i if limit
      limit = DEFAULT_FINISHED_JOBS_PER_QUEUE if limit.nil? || limit <= 0
      limit
    end

    def store(name, value, freeze: true)
      services[name] = freeze ? deep_freeze(value) : value
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each do |k, v|
          deep_freeze(k)
          deep_freeze(v)
        end
        value.freeze
      when Array
        value.each { |entry| deep_freeze(entry) }
        value.freeze
      when String
        value.freeze
      else
        value
      end
    end

    def placeholder_value?(value)
      return true if value.to_s.strip.empty?

      value.to_s.match?(/torznab_api_(url|key)/) ||
        %w[https://torznab.example/api replace-with-api-key].include?(value) ||
        value.to_s.include?('tracker.example')
    end

    def deep_dup(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, val), memo|
          memo[key] = deep_dup(val)
        end
      when Array
        value.map { |entry| deep_dup(entry) }
      else
        value
      end
    end

    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, val), memo|
          memo[key.to_s] = stringify_keys(val)
        end
      when Array
        value.map { |entry| stringify_keys(entry) }
      else
        value
      end
    end

    def fetch_caps_diagnostic(api_url)
      uri = URI.parse(api_url.to_s)
      response = Net::HTTP.get_response(uri)
      body = response.body.to_s
      prefix = body.length > 400 ? "#{body[0, 400]}...[truncated]" : body
      [body, prefix]
    rescue StandardError
      ['', '']
    end
  end
end

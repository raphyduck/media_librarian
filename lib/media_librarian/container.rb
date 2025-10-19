# frozen_string_literal: true

require 'yaml'

require 'simple_args_dispatch' unless defined?(SimpleArgsDispatch)
require 'simple_config_man' unless defined?(SimpleConfigMan)
require 'simple_speaker' unless defined?(SimpleSpeaker)

require_relative '../db' unless defined?(Storage::Db)
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

    def workers_pool_size
      services.fetch(:workers_pool_size)
    end

    def queue_slots
      services.fetch(:queue_slots)
    end

    private

    attr_reader :services

    def bootstrap!
      store(:config, SimpleConfigMan.load_settings(application.config_dir,
                                                  application.config_file,
                                                  application.config_example))

      store(:speaker, SimpleSpeaker::Speaker.new, freeze: false)
      store(:args_dispatch, SimpleArgsDispatch::Agent.new(speaker, application.env_flags), freeze: false)

      store(:db, Storage::Db.new(File.join(application.config_dir, 'librarian.db')), freeze: false)

      store(:trackers, build_trackers)

      store(:str_closeness, FuzzyStringMatch::JaroWinkler.create(:pure), freeze: false)
      store(:tracker_client, {}, freeze: false)
      store(:tracker_client_last_login, {}, freeze: false)

      store(:api_option, 'bind_address' => '127.0.0.1', 'listen_port' => '8888')

      daemon_config = config.fetch('daemon', {})
      store(:workers_pool_size, daemon_config['workers_pool_size'] || 4, freeze: true)
      store(:queue_slots, daemon_config['queue_slots'] || 4, freeze: true)
    end

    def build_trackers
      return {} unless File.directory?(application.tracker_dir)

      Dir.each_child(application.tracker_dir).each_with_object({}) do |tracker, memo|
        file_path = File.join(application.tracker_dir, tracker)
        next unless File.file?(file_path)

        opts = YAML.load_file(file_path)
        next unless opts['api_url'] && opts['api_key']

        tracker_name = tracker.sub(/\.yml$/, '')
        memo[tracker_name] = TorznabTracker.new(opts, tracker_name)
      rescue StandardError => e
        speaker.tell_error(e, Utils.arguments_dump(binding)) if speaker.respond_to?(:tell_error)
      end
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
  end
end

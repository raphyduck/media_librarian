# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'yaml'

module TestSupport
  module ContainerHelpers
    def build_stubbed_environment(**overrides)
      StubbedEnvironment.new(**overrides)
    end

    class StubbedEnvironment
      attr_reader :application, :container, :root_path

      def initialize(speaker: TestSupport::Fakes::Speaker.new,
                     args_dispatch: TestSupport::Fakes::ArgsDispatch.new)
        @root_path = Dir.mktmpdir('librarian-test')
        FileUtils.mkdir_p(File.join(@root_path, 'init'))
        @application = StubApplication.new(root: @root_path,
                                           speaker: speaker,
                                           args_dispatch: args_dispatch)
        @container = StubContainer.new(application: @application)
        @application.container = @container
      end

      def cleanup
        FileUtils.remove_entry(root_path) if root_path && Dir.exist?(root_path)
      end
    end

    class StubApplication
      attr_accessor :librarian, :speaker, :args_dispatch,
                    :workers_pool_size, :queue_slots, :container,
                    :email, :email_templates
      attr_reader :root, :loader, :template_dir, :pidfile,
                  :env_flags, :config_dir, :config_file, :config_example,
                  :tracker_dir, :api_config_file

      attr_accessor :trakt

      def initialize(root:, speaker:, args_dispatch:)
        @root = root
        @loader = NullLoader.new
        @env_flags = {}
        @config_dir = File.join(root, 'config')
        FileUtils.mkdir_p(@config_dir)
        @config_file = File.join(@config_dir, 'conf.yml')
        @config_example = File.join(@config_dir, 'conf.yml.example')
        @api_config_file = File.join(@config_dir, 'api.yml')
        @template_dir = File.join(root, 'templates')
        FileUtils.mkdir_p(@template_dir)
        @tracker_dir = File.join(root, 'trackers')
        FileUtils.mkdir_p(@tracker_dir)
        pid_dir = File.join(root, 'tmp')
        FileUtils.mkdir_p(pid_dir)
        @pidfile = File.join(pid_dir, 'librarian.pid')
        @api_option = default_api_option
        @workers_pool_size = 2
        @queue_slots = 2
        @speaker = speaker
        @args_dispatch = args_dispatch
        persist_default_configuration
        persist_default_api_configuration
      end

      class NullLoader
        def eager_load; end
      end

      def persist_default_configuration
        return if File.exist?(@config_file)

        File.write(@config_file, { 'daemon' => { 'workers_pool_size' => @workers_pool_size,
                                                 'queue_slots' => @queue_slots } }.to_yaml)
      end

      def persist_default_api_configuration
        return if File.exist?(@api_config_file)

        File.write(@api_config_file, default_api_option.to_yaml)
      end

      def config
        container&.config || {}
      end

      def api_option
        @api_option
      end

      def api_option=(value)
        @api_option = default_api_option.merge(stringify_keys(value || {})) do |key, default_value, override|
          if default_value.is_a?(Hash) && override.is_a?(Hash)
            default_value.merge(override)
          else
            override
          end
        end
        File.write(@api_config_file, @api_option.to_yaml)
      end

      private

      def default_api_option
        {
          'bind_address' => '127.0.0.1',
          'listen_port' => 8888,
          'auth' => {},
          'ssl_enabled' => false,
          'ssl_certificate_path' => nil,
          'ssl_private_key_path' => nil,
          'ssl_ca_path' => nil,
          'ssl_verify_mode' => 'none',
          'ssl_client_verify_mode' => 'none'
        }
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
    end

    class StubContainer
      attr_reader :application
      attr_accessor :config, :workers_pool_size, :queue_slots, :trackers

      def initialize(application:)
        @application = application
        @config = SimpleConfigMan.load_settings(nil, application.config_file, nil)
        daemon_config = @config.fetch('daemon', {})
        @workers_pool_size = daemon_config['workers_pool_size'] || application.workers_pool_size
        @queue_slots = daemon_config['queue_slots'] || application.queue_slots
        @trackers = {}
      end

      def reload_api_option!
        return unless File.exist?(application.api_config_file)

        loaded = YAML.safe_load(File.read(application.api_config_file), aliases: true) || {}
        application.api_option = loaded
      end

      def reload_config!(new_settings)
        @config = new_settings
        daemon_config = new_settings.fetch('daemon', {})
        @workers_pool_size = daemon_config['workers_pool_size'] || @workers_pool_size
        @queue_slots = daemon_config['queue_slots'] || @queue_slots
        application.workers_pool_size = @workers_pool_size
        application.queue_slots = @queue_slots
        self
      end

      def build_trackers
        return {} unless File.directory?(application.tracker_dir)

        Dir.each_child(application.tracker_dir).each_with_object({}) do |filename, memo|
          path = File.join(application.tracker_dir, filename)
          next unless File.file?(path) && filename.end_with?('.yml')

          tracker_name = filename.sub(/\.yml\z/, '')
          memo[tracker_name] = YAML.safe_load(File.read(path), aliases: true) || {}
        end
      end
    end
  end

  module Fakes
    class Speaker
      attr_reader :messages

      def initialize
        @messages = []
      end

      def speak_up(message, *_args)
        @messages << message
      end

      def tell_error(error, context = nil, *_args)
        @messages << [:error, error, context]
      end
    end

    class ArgsDispatch
      attr_reader :dispatched_commands, :shown_actions

      def initialize
        @dispatched_commands = []
        @shown_actions = []
      end

      def dispatch(app_name, command, actions, *_rest)
        @dispatched_commands << { app: app_name, command: command.dup, actions: actions }
        :dispatched
      end

      def launch(app_name, action, args, *_rest)
        @dispatched_commands << { app: app_name, command: args.dup, actions: action }
        constant_name, method_name = action

        return :launched unless constant_name == 'Daemon'

        constant = Object.const_get(constant_name)
        constant.public_send(method_name, *args)
      end

      def show_available(app_name, actions)
        @shown_actions << { app: app_name, actions: actions }
        :shown
      end

      def set_env_variables(*)
        # no-op in tests
      end

      def load_template(name, template_dir)
        path = File.join(template_dir, "#{name}.yml")
        return {} unless File.exist?(path)

        YAML.safe_load(File.read(path), aliases: true) || {}
      end
    end
  end
end

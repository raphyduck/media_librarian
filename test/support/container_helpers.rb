# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

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
      end

      def cleanup
        FileUtils.remove_entry(root_path) if root_path && Dir.exist?(root_path)
      end
    end

    class StubContainer
      attr_reader :application

      def initialize(application:)
        @application = application
      end
    end

    class StubApplication
      attr_accessor :librarian, :speaker, :args_dispatch
      attr_reader :root, :loader, :template_dir, :pidfile,
                  :env_flags, :config_dir, :config_file, :config_example

      def initialize(root:, speaker:, args_dispatch:)
        @root = root
        @loader = NullLoader.new
        @env_flags = {}
        @config_dir = File.join(root, 'config')
        FileUtils.mkdir_p(@config_dir)
        @config_file = File.join(@config_dir, 'conf.yml')
        @config_example = File.join(@config_dir, 'conf.example.yml')
        @template_dir = File.join(root, 'templates')
        FileUtils.mkdir_p(@template_dir)
        pid_dir = File.join(root, 'tmp')
        FileUtils.mkdir_p(pid_dir)
        @pidfile = File.join(pid_dir, 'librarian.pid')
        @speaker = speaker
        @args_dispatch = args_dispatch
      end

      class NullLoader
        def eager_load; end
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

      def tell_error(error, context = nil)
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

      def show_available(app_name, actions)
        @shown_actions << { app: app_name, actions: actions }
        :shown
      end

      def set_env_variables(*)
        # no-op in tests
      end
    end
  end
end

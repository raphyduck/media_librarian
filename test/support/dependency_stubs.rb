# frozen_string_literal: true

# Minimal dependency stubs that allow the CLI to execute inside the test
# environment without booting the full application stack. Only the methods used
# by the integration tests are implemented.
require 'yaml'
unless defined?(Daemon)
  class Daemon
    class << self
      def is_daemon?
        false
      end

      def running?
        false
      end

      def thread_cache_add(*)
        # no-op in tests
      end

      def job_id
        'test-job'
      end

      def dump_env_flags(*)
        {}
      end

      def fetch_function_config(*)
        []
      end

      def get_children_count(*)
        0
      end

      def clear_waiting_worker(*)
        # no-op in tests
      end

      def consolidate_children(*)
        # no-op in tests
      end

      def merge_notifications(*)
        # no-op in tests
      end
    end
  end
end

unless defined?(LibraryBus)
  class LibraryBus
    class << self
      def initialize_queue(*)
        queues
      end

      def put_in_queue(value, thread = Thread.current)
        queues[thread.object_id] << value unless value.nil?
      end

      def merge_queue(thread = Thread.current)
        queues.delete(thread.object_id)
      end

      private

      def queues
        @queues ||= Hash.new { |memo, key| memo[key] = [] }
      end
    end
  end
end

unless defined?(TimeUtils)
  module TimeUtils
    module_function

    def seconds_in_words(_seconds)
      '0 seconds'
    end
  end
end

if defined?(Utils)
  class Utils
    class << self
      def lock_time_get(*)
        ''
      end

      def lock_block(*)
        yield if block_given?
      end

      def lock_time_merge(*)
        # no-op in tests
      end

      def arguments_dump(*)
        'arguments'
      end

      def recursive_typify_keys(value)
        value
      end

      def parse_filename_template(template, _metadata)
        template
      end

      def check_if_active(*)
        true
      end

      def timeperiod_to_sec(*)
        0
      end
    end
  end
else
  class Utils
    class << self
      def lock_time_get(*)
        ''
      end

      def lock_block(*)
        yield if block_given?
      end

      def lock_time_merge(*)
        # no-op in tests
      end

      def arguments_dump(*)
        'arguments'
      end

      def recursive_typify_keys(value)
        value
      end

      def parse_filename_template(template, _metadata)
        template
      end

      def check_if_active(*)
        true
      end

      def timeperiod_to_sec(*)
        0
      end
    end
  end
end

unless defined?(Report)
  class Report
    class << self
      def sent_out(*)
        # no-op in tests
      end

      def push_email(*)
        # no-op in tests
      end
    end
  end
end

unless defined?(Env)
  class Env
    class << self
      def email_notif?(*_args)
        false
      end

      def debug?(*_args)
        false
      end

      def pretend?(*_args)
        false
      end
    end
  end
end

unless defined?(ExecutionHooks)
  module ExecutionHooks
    module_function

    def on_the_fly_hooking(*)
      # no-op in tests
    end

    def alias_hook(sym)
      "__#{sym}__hooked__"
    end
  end
end

module SimpleConfigMan
  module_function

  DEFAULT_SETTINGS = {
    'preferred_languages' => ['en'],
    'daemon' => {
      'workers_pool_size' => 2,
      'queue_slots' => 2
    },
    'calendar' => {
      'refresh_every' => '12 hours',
      'refresh_on_start' => true,
      'refresh_days' => 45,
      'refresh_limit' => 200,
      'providers' => 'imdb|trakt|tmdb'
    }
  }.freeze

  def load_settings(_config_dir = nil, config_file = nil, _config_example = nil)
    return DEFAULT_SETTINGS unless config_file && File.exist?(config_file)

    loaded = YAML.safe_load(File.read(config_file), aliases: true)
    merge_defaults(loaded)
  rescue StandardError
    DEFAULT_SETTINGS
  end

  def reconfigure(*_args)
    # no-op in tests
  end

  def merge_defaults(loaded)
    return DEFAULT_SETTINGS unless loaded.is_a?(Hash)

    DEFAULT_SETTINGS.merge(loaded) do |key, default_value, loaded_value|
      if default_value.is_a?(Hash) && loaded_value.is_a?(Hash)
        default_value.merge(loaded_value)
      else
        loaded_value || default_value
      end
    end
  end
  private_class_method :merge_defaults
end

module Storage
  class Db
    def initialize(*); end

    def method_missing(*)
      nil
    end

    def respond_to_missing?(*_args)
      true
    end
  end
end

module FuzzyStringMatch
  class JaroWinkler
    def self.create(*)
      new
    end

    def distance(*)
      1.0
    end
  end
end

unless defined?(Cache)
  class Cache
    class << self
      def queue_state_add_or_update(*)
        # no-op in tests
      end

      def queue_state_remove(*)
        # no-op in tests
      end

      def queue_state_get(*)
        []
      end

      def object_pack(value, *_args)
        value
      end

      def object_unpack(value, *_args)
        value
      end
    end
  end
end

unless {}.respond_to?(:deep_dup)
  class Hash
    def deep_dup
      each_with_object({}) do |(key, value), memo|
        memo[key] = value.respond_to?(:deep_dup) ? value.deep_dup : value.dup rescue value
      end
    end
  end

  class Array
    def deep_dup
      map { |value| value.respond_to?(:deep_dup) ? value.deep_dup : value.dup rescue value }
    end
  end
end

# frozen_string_literal: true

# Minimal dependency stubs that allow the CLI to execute inside the test
# environment without booting the full application stack. Only the methods used
# by the integration tests are implemented.
unless defined?(Daemon)
  class Daemon
    class << self
      def is_daemon?
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

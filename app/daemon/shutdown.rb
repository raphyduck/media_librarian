# frozen_string_literal: true

# Graceful shutdown and cleanup for the daemon: quit/shutdown orchestration,
# executor drain, restart-vs-full-stop distinction, signal traps, and closing
# the database and daemon lock. Reopens Daemon's singleton class so these
# methods stay byte-for-byte identical to their prior inline definitions;
# extracted purely to shrink app/daemon.rb. Zeitwerk is told to ignore this
# file (see Application#setup_loader) because it reopens Daemon rather than
# defining a Daemon::Shutdown constant.

class Daemon
  class << self
    def quit
      return unless running?
      return unless app.librarian.quit?

      shutdown
    end

    def shutdown
      return unless running?

      @running.make_false

      begin
        [@scheduler, @quit_timer, @trakt_timer].compact.each do |timer|
          timer.shutdown
          timer.wait_for_termination
        end

        @control_server&.shutdown
        if @control_thread && @control_thread.alive? && @control_thread != Thread.current
          @control_thread.join
        end
        close_socket_server

        if @executor
          @executor.shutdown
          wait_for_executor_shutdown
        end
      rescue StandardError => e
        app.speaker.tell_error(e, Utils.arguments_dump(binding))
      ensure
        close_db
        close_daemon_lock unless restart_requested_flag.true?
        @stop_event&.set
      end
    end

    def wait_for_executor_shutdown
      return @executor.wait_for_termination unless restart_shutdown? || force_shutdown_flag.true?

      timeout = restart_shutdown_timeout
      return @executor.wait_for_termination if timeout.nil?
      return if @executor.wait_for_termination(timeout)

      app.speaker.speak_up("Shutdown timed out after #{timeout}s; forcing executor shutdown")
      @executor.kill if @executor.respond_to?(:kill)
    end

    def restart_shutdown?
      restart_requested_flag.true?
    end

    def restart_shutdown_timeout
      timeout = ENV.fetch('MEDIA_LIBRARIAN_RESTART_SHUTDOWN_TIMEOUT', '20').to_f
      timeout.positive? ? timeout : nil
    end

    def wait_for_shutdown
      @stop_event.wait
    end

    def cleanup
      @force_shutdown_flag&.make_false
      @force_shutdown_flag = nil
      @scheduler = nil
      @quit_timer = nil
      @trakt_timer = nil
      @control_thread = nil
      @control_server = nil
      @socket_thread = nil
      @socket_server = nil
      @executor = nil
      @template_cache = nil
      @queue_limits = nil
      @running = nil
      @stop_event = nil
      @is_daemon = false
      @scheduler_name = nil
      @session_cookie_secure = nil
    end

    def install_signal_traps
      return if @signal_traps_installed

      %w[INT TERM].each do |signal|
        Signal.trap(signal) { handle_signal(signal) }
      end
      @signal_traps_installed = true
    end

    def handle_signal(signal)
      return unless running?

      app.speaker.speak_up("Received #{signal}, shutting down...")
      app.librarian.quit = true if app.respond_to?(:librarian) && app.librarian
      shutdown
    end

    def close_db
      db = app.respond_to?(:db) ? app.db : nil
      database = db&.respond_to?(:database) ? db.database : nil
      return unless database

      if database.respond_to?(:disconnect)
        database.disconnect
      elsif database.respond_to?(:close)
        database.close
      end
    rescue StandardError => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding))
    end

    def close_daemon_lock
      @daemon_lock&.close
      @daemon_lock = nil
    end
  end
end

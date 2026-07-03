# frozen_string_literal: true

# Daemon lifecycle control for the control server: config/api/scheduler reload
# endpoints, restart, and git-based self-update (update-stop). Reopens Daemon's
# singleton class so these methods stay byte-for-byte identical to their prior
# inline definitions; extracted purely to shrink app/daemon.rb. Zeitwerk is
# told to ignore this file (see Application#setup_loader) because it reopens
# Daemon rather than defining a Daemon::Lifecycle constant.

class Daemon
  class << self
    def handle_config_reload_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'

      process_reload_request(res) { reload }
    end

    def handle_api_config_reload_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'

      process_reload_request(res) { reload_api_option_config }
    end

    def handle_scheduler_reload_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'
      return error_response(res, status: 404, message: 'scheduler_not_configured') unless @scheduler_name

      process_reload_request(res) { reload_scheduler }
    end

    def handle_restart_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'

      outcome = restart
      case outcome
      when :scheduled
        json_response(res, status: 202, body: { 'status' => 'restarting' })
      when :already_restarting
        error_response(res, status: 409, message: 'restart_in_progress')
      when :not_running
        error_response(res, status: 503, message: 'not_running')
      else
        error_response(res, status: 500, message: 'restart_failed')
      end
    end

    def handle_update_stop_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'
      return error_response(res, status: 503, message: 'not_running') unless running?

      root = update_root
      unless File.directory?(root) && File.directory?(File.join(root, '.git'))
        return error_response(res, status: 404, message: 'update_root_missing')
      end

      updated, error = update_code(root)
      unless updated
        return error_response(res, status: 500, message: error || 'update_failed')
      end

      json_response(res, status: 202, body: { 'status' => 'update_stopping' })
      force_shutdown_flag.make_true
      Thread.new { stop }
    end

    def process_reload_request(res)
      unless running?
        return error_response(res, status: 503, message: 'not_running')
      end

      outcome = yield
      if outcome
        json_response(res, status: 204)
      else
        error_response(res, status: 500, message: 'reload_failed')
      end
    rescue StandardError => e
      error_response(res, status: 500, message: e.message)
    end

    def restart_requested_flag
      @restart_requested_flag ||= Concurrent::AtomicBoolean.new(false)
    end

    def force_shutdown_flag
      @force_shutdown_flag ||= Concurrent::AtomicBoolean.new(false)
    end

    def update_root
      opts = app.api_option || {}
      root = opts['update_root'].to_s.strip
      root = app.root if root.empty?
      File.expand_path(root)
    end

    def update_code(root)
      success, error = run_git_command(root, ['git', 'fetch', '--all'])
      return [false, error] unless success
      success, error = run_git_command(root, ['git', 'pull', '--ff-only'])
      return [false, error] unless success
      true
    end

    def run_git_command(root, command)
      _out, err, status = Open3.capture3(*command, chdir: root)
      return [true, nil] if status.success?

      message = err.to_s.lines.first.to_s.strip
      [false, message.empty? ? 'git_command_failed' : message]
    rescue Errno::ENOENT
      [false, 'git_command_failed']
    end

    def restart_from_disk
      return :not_running unless ensure_daemon

      command = restart_command
      unless command
        app.speaker.speak_up('Restart command missing; cannot restart daemon')
        return :failed
      end

      stop
      exec(*command)
    rescue StandardError => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding))
      :failed
    end

    def restart_command
      command = @restart_command
      return if command.nil? || command.empty?

      program, *args = command
      program_path = if File.file?(File.join(app.root, program))
                       File.expand_path(program, app.root)
                     else
                       program
                     end

      [program_path, *args]
    end
  end
end

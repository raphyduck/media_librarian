# frozen_string_literal: true

require_relative 'boot/librarian'
require_relative 'lib/media_librarian/command_registry'
require_relative 'lib/media_librarian/app_container_support'
require_relative 'lib/thread_state'

autoload :Env, File.expand_path('lib/env.rb', __dir__) unless defined?(Env)

class Librarian
  include MediaLibrarian::AppContainerSupport

  attr_accessor :args, :quit, :reload
  attr_reader :command_registry, :app, :container

  class << self
    attr_accessor :debug_classes

    def command_registry
      return app.librarian.command_registry if app.librarian

      @command_registry ||= MediaLibrarian::CommandRegistry.new(app)
    end
  end

  self.debug_classes = []

  def initialize(container:, args: ARGV)
    @container = container
    app = container.application
    self.class.configure(app: app)
    @app = app
    @args = args
    @loaded = false
    @command_registry = MediaLibrarian::CommandRegistry.new(app)
    app.librarian = self
  end

  def daemonize
    Process.daemon
    exit if fork
    Process.setsid
    exit if fork
    Dir.chdir('/')
    suppress_output
  end

  def leave
    app.speaker.speak_up('End of session, good bye...')
  end

  def loaded?
    @loaded
  end

  def write_pid
    begin
      File.open(app.pidfile, ::File::CREAT | ::File::EXCL | ::File::WRONLY) do |f|
        f.write(Process.pid.to_s)
      end
      at_exit { File.delete(app.pidfile) if File.exist?(app.pidfile) }
    rescue Errno::EEXIST
      check_pid
      retry
    end
  end

  def check_pid
    case pid_status(app.pidfile)
    when :running, :not_owned
      app.speaker.speak_up("A server is already running. Check #{app.pidfile}")
      exit(1)
    when :dead
      delete_pid
    end
  end

  def delete_pid
    File.delete(app.pidfile)
  end

  def pid_status(pidfile)
    return :exited unless File.exist?(pidfile)
    pid = ::File.read(pidfile).to_i
    return :dead if pid.zero?

    Process.kill(0, pid)
    :running
  rescue Errno::ENOENT
    :exited
  rescue Errno::ESRCH
    :dead
  rescue Errno::EPERM
    :not_owned
  end

  def quit?
    quit || reload
  end

  def load_requirements
    return if @loaded

    app.loader.eager_load
    Dir[File.join(app.root, 'init', '*.rb')].sort.each { |file| require file }
    @loaded = true
  end

  def run!
    trap_signals
    ExecutionHooks.on_the_fly_hooking(self.class.debug_classes)
    app.speaker.speak_up("Welcome to your library assistant!\n\n")
    self.class.route_cmd(args)
  end

  def suppress_output
    $stderr.reopen('/dev/null', 'a')
    $stdout.reopen($stderr)
  end

  def trap_signals
    trap('QUIT') { @quit = true }
  end

  class << self
    def burst_thread(tid = Daemon.job_id, client = nil, parent = nil, envf = Daemon.dump_env_flags, child = 0, queue_name = '', &block)
      Thread.new do
        app.args_dispatch.set_env_variables(app.env_flags, envf)
        reset_notifications(Thread.current)
        Thread.current[:log_msg] = String.new if child.to_i > 0
        Thread.current[:current_daemon] = client || Thread.current[:current_daemon]
        Thread.current[:parent] = parent
        Thread.current[:jid] = tid
        Thread.current[:queue_name] = queue_name
        LibraryBus.initialize_queue(Thread.current)
        block.call
      end
    end

    def help
      app.args_dispatch.show_available(MediaLibrarian::APP_NAME, command_registry.actions)
    end

    def init_thread(thread, object = '', direct = 0, &block)
      reset_notifications(thread)
      thread[:object] = object
      thread[:start_time] = Time.now
      thread[:direct] = direct
      thread[:block] = [block]
      thread[:child_job] = 0
      thread[:is_active] = 1
    end

    def reconfigure
      if Daemon.is_daemon?
        return app.speaker.speak_up('Can not configure application when launched as a daemon')
      end

      SimpleConfigMan.reconfigure(app.config_file, app.config_example)
    end

    def route_cmd(args, internal = 0, task = 'exclusive', _max_pool_size = 1, queue = Thread.current[:jid], &block)
      config = Array(Daemon.fetch_function_config(args))
      proxy_internal = internal
      direct_flag = internal

      unless config.empty?
        queue_from_config = config[1]
        internal_from_config = config[2]

        if proxy_internal.to_i.zero? && !internal_from_config.nil?
          proxy_internal = internal_from_config
          direct_flag = internal_from_config
        end

        if queue_from_config && (queue.nil? || queue == Thread.current[:jid])
          queue = queue_from_config
          task = queue_from_config if task == 'exclusive'
        end

        if proxy_internal.to_i.zero? && args.first.to_s.casecmp('daemon').zero?
          # `daemon status` and `daemon stop` need to execute in-process so they can
          # call the appropriate `Client` methods directly and stream output to the CLI.
          # Other daemon subcommands should continue to be routed through the daemon.
          subcommand = args[1].to_s
          if %w[status stop].any? { |cmd| subcommand.casecmp(cmd).zero? }
            proxy_internal = 1
            direct_flag = 1
            ENV['MEDIA_LIBRARIAN_CLIENT_MODE'] ||= '1'
          end
        end
      end

      if Daemon.running?
        Daemon.enqueue(
          args: args,
          queue: queue,
          task: task,
          internal: proxy_internal,
          client: Thread.current[:current_daemon],
          child: 1,
          env_flags: Daemon.dump_env_flags,
          parent_thread: Thread.current,
          &block
        )
      elsif app.librarian.pid_status(app.pidfile) == :running && proxy_internal.to_i.zero?
        return if args.nil? || args.empty?

        app.speaker.speak_up('A daemon is already running, sending execution there and waiting for acknowledgement')
        ENV['MEDIA_LIBRARIAN_CLIENT_MODE'] = '1'
        response = Client.new.enqueue(
          args,
          wait: true,
          queue: queue,
          task: task,
          internal: proxy_internal,
          capture_output: true
        )
        status_code = response['status_code'].to_i
        body = response['body']

        if response['error']
          app.speaker.speak_up("Daemon rejected the job: #{response['error']}")
        elsif status_code >= 400
          error_detail = body.is_a?(Hash) ? body['error'] || body['message'] : nil
          message = error_detail ? "#{error_detail} (HTTP #{status_code})" : "HTTP #{status_code}"
          if [401, 403].include?(status_code)
            message = "#{message}. Check the control token configuration for the daemon."
          end
          app.speaker.speak_up("Daemon rejected the job: #{message}")
        elsif body && body['job']
          job = body['job']
          output = job['output'].to_s
          unless output.empty?
            output.each_line { |line| app.speaker.daemon_send(line, stdout: $stdout, stderr: $stderr) }
            return
          end
          status = job['status'].to_s
          status = 'queued' if status.empty?
          app.speaker.speak_up("Job #{job['id']} acknowledged (status: #{status})")
        else
          app.speaker.speak_up('Command dispatched to daemon')
        end
      else
        app.librarian.load_requirements unless app.librarian.loaded?
        thread = Thread.current
        LibraryBus.initialize_queue(thread)
        ThreadState.around(thread) do |snapshot|
          nested = thread[:is_active].to_i > 0
          thread[:child_job_override] = 1 if nested
          run_command(args, direct_flag)
          if nested && snapshot[:email_msg]
            snapshot[:email_msg] << thread[:email_msg].to_s
            snapshot[:send_email] = thread[:send_email] if thread[:send_email].to_i.positive?
          end
        end
      end
    end

    def reset_notifications(thread)
      thread[:email_msg] = String.new
      thread[:send_email] = 0
    end

    def run_command(cmd, direct = 0, object = '', &block)
      original_cmd = Array(cmd).dup
      cmd = sanitize_arguments(original_cmd)

      if direct.to_i.zero? && cmd.empty?
        notify_missing_command(original_cmd)
        cmd = ['help']
      end

      sanitized_cmd = cmd.dup
      running_command = sanitized_cmd
        .map { |a| a.is_a?(String) ? a.gsub(/--?([^=\s]+)(?:=(.+))?/, '--\1=\'\2\'') : a.inspect }
        .join(' ')

      child_job = Thread.current[:child_job].to_i.positive? || Thread.current[:parent]
      object = cmd[0..1].join(' ') if object.to_s.empty? || object == 'rcv'
      init_thread(Thread.current, object, direct, &block)

      unless internal_email_command?(object, sanitized_cmd) || child_job
        app.speaker.speak_up(String.new('Running command: '), 0)
        app.speaker.speak_up("#{running_command}\n\n", 0)
      end

      thread_value =
        if direct.to_i > 0
          m = cmd.shift
          a = cmd.shift

          if cli_direct_invocation?(m)
            action = find_action(sanitized_cmd)
            raise NameError, "Unknown command '#{original_cmd.first(2).join(' ')}'" unless action

            app.args_dispatch.launch(MediaLibrarian::APP_NAME, action, cmd, original_cmd.first(2).join(' '), app.template_dir)
          else
            p = resolve_constant(m).method(a.to_sym)
            cmd.empty? ? p.call : p.call(*cmd)
          end
        else
          app.args_dispatch.dispatch(MediaLibrarian::APP_NAME, cmd, command_registry.actions, nil, app.template_dir)
        end

      run_termination(Thread.current, thread_value)
    rescue StandardError => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding))
      run_termination(Thread.current, thread_value, "Error on #{object}")
    end

    def sanitize_arguments(args)
      sanitized = []
      skip_next = false

      Array(args).each do |arg|
        if skip_next
          skip_next = false
          next
        end

        case arg
        when '--config'
          skip_next = true
        when /^--config=/
          next
        else
          sanitized << arg
        end
      end

      sanitized
    end

    def resolve_constant(name)
      return name if name.is_a?(Module)

      const_name = name.to_s

      Object.const_get(const_name)
    rescue NameError
      normalized = const_name.split('::').map do |segment|
        segment.split('_').map { |part| part.capitalize }.join
      end.join('::')

      Object.const_get(normalized)
    end
    private :resolve_constant

    def cli_direct_invocation?(token)
      token.to_s.match?(/\A[a-z]/)
    end
    private :cli_direct_invocation?

    def internal_email_command?(object, command)
      object.to_s == 'email' || Array(command).map(&:to_s).first(2) == %w[Report push_email]
    end
    private :internal_email_command?

    def find_action(tokens)
      names = Array(tokens).take_while { |arg| arg.to_s !~ /^-/ }
      return nil if names.empty?

      config = command_registry.actions
      names.each do |segment|
        entry = config[segment.to_sym] if config
        return entry unless entry.is_a?(Hash)
        config = entry
      end
    end
    private :find_action

    def notify_missing_command(original_cmd)
      return unless original_cmd.any?

      if original_cmd.any? { |arg| arg == '--config' || arg.start_with?('--config=') }
        app.speaker.speak_up('No command provided after --config option, showing help instead.')
      else
        app.speaker.speak_up('No command provided, showing help instead.')
      end
    end

    def run_termination(thread, thread_value, object = nil)
      thread[:end_time] = Time.now
      thread[:is_active] = 0
      child_job_override = thread[:child_job_override]
      thread[:child_job] = child_job_override.to_i if !child_job_override.nil?
      Daemon.clear_waiting_worker(thread, thread_value, object)
      terminate_command(thread, thread_value, object)
    end

    def terminate_command(thread, thread_value = nil, object = nil)
      return unless thread[:base_thread].nil?
      return if Daemon.get_children_count(thread[:jid]).to_i > 0 || thread[:is_active] > 0

      LibraryBus.put_in_queue(thread_value)
      if thread[:direct].to_i.zero?
        elapsed_time = Time.now - thread[:start_time]
        time_info = TimeUtils.seconds_in_words(elapsed_time)
        lock_time = Utils.lock_time_get(thread)
        app.speaker.speak_up("Command '#{thread[:object]}' executed in #{time_info},#{lock_time}", 0, thread)
      end
      if thread[:block].is_a?(Array) && !thread[:block].empty?
        thread[:block].reverse_each { |b| b.call rescue nil }
      end
      if thread[:parent]
        Utils.lock_block("merge_child_thread_#{thread[:object]}") { Daemon.merge_notifications(thread, thread[:parent]) }
      elsif thread[:child_job].to_i.positive?
        # Inline child jobs share the parent's thread, so email delivery should be deferred
      elsif Env.email_notif?
        Report.sent_out("#{'[DEBUG]' if Env.debug?(thread)}#{object || thread[:object]}", thread)
      end
      Daemon.clear_waiting_worker(thread, thread_value, object, 1)
    end

    def test_childs(how_many: 10_000)
      (0...how_many.to_i).each do |i|
        Librarian.route_cmd(
          ['Librarian', 'da_child', i],
          1,
          Thread.current[:object].to_s,
          6
        )
      end
      app.speaker.speak_up("Finale result is #{Daemon.consolidate_children}")
    end

    def da_child(i = '')
      app.speaker.speak_up("i is '#{i}'")
      1
    end
  end
end

if $PROGRAM_NAME == __FILE__
  container = MediaLibrarian::Boot.container
  librarian = Librarian.new(container: container)
  arguments = librarian.args.dup
  first_time = true

  while ((librarian.reload && !Daemon.is_daemon?) || first_time)
    first_time = false
    librarian.args = arguments.dup
    librarian.reload = false
    librarian.run!
  end

  librarian.leave
end

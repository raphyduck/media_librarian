# frozen_string_literal: true

require_relative 'boot/librarian'
require_relative 'lib/media_librarian/command_registry'
require_relative 'lib/media_librarian/app_container_support'

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
        Thread.current[:log_msg] = '' if child.to_i > 0
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
      thread[:is_active] = 1
    end

    def reconfigure
      if Daemon.is_daemon?
        return app.speaker.speak_up('Can not configure application when launched as a daemon')
      end

      SimpleConfigMan.reconfigure(app.config_file, app.config_example)
    end

    def route_cmd(args, internal = 0, task = 'exclusive', max_pool_size = 1, queue = Thread.current[:jid], &block)
      if Daemon.is_daemon?
        Daemon.thread_cache_add(queue, args, Daemon.job_id, task, internal, max_pool_size, 0,
                                Daemon.fetch_function_config(args)[2] || 0,
                                Thread.current[:current_daemon], 43_200, 1, &block)
      elsif app.librarian.pid_status(app.pidfile) == :running && internal.to_i.zero?
        return if args.nil? || args.empty?

        app.speaker.speak_up('A daemon is already running, sending execution there and waiting to get an execution slot')
        EventMachine.run do
          EventMachine.connect '127.0.0.1', app.api_option['listen_port'], Client, args
          EM.open_keyboard(ClientInput)
        end
      else
        app.librarian.load_requirements unless app.librarian.loaded?
        LibraryBus.initialize_queue(Thread.current)
        run_command(args, internal)
      end
    end

    def reset_notifications(thread)
      thread[:email_msg] = ''
      thread[:send_email] = 0
    end

    def run_command(cmd, direct = 0, object = '', &block)
      object = cmd[0..1].join(' ') if object.to_s.empty? || object == 'rcv'
      init_thread(Thread.current, object, direct, &block)

      thread_value =
        if direct.to_i > 0
          m = cmd.shift
          a = cmd.shift
          p = Object.const_get(m).method(a.to_sym)
          cmd.nil? ? p.call : p.call(*cmd)
        else
          app.speaker.speak_up('Running command: ', 0)
          app.speaker.speak_up("#{cmd.map { |a| a.gsub(/--?([^=\s]+)(?:=(.+))?/, '--\1=\'\2\'') }.join(' ')}\n\n", 0)
          app.args_dispatch.dispatch(MediaLibrarian::APP_NAME, cmd, command_registry.actions, nil, app.template_dir)
        end

      run_termination(Thread.current, thread_value)
    rescue StandardError => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding))
      run_termination(Thread.current, thread_value, "Error on #{object}")
    end

    def run_termination(thread, thread_value, object = nil)
      thread[:end_time] = Time.now
      thread[:is_active] = 0
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
      Report.sent_out("#{'[DEBUG]' if Env.debug?(thread)}#{object || thread[:object]}", thread) if Env.email_notif? && thread[:direct].to_i.zero?
      if thread[:parent]
        Utils.lock_block("merge_child_thread_#{thread[:object]}") { Daemon.merge_notifications(thread, thread[:parent]) }
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

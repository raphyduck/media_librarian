# encoding: UTF-8

# Constants for required gems
MIN_REQ = %w(
  bundler/setup eventmachine fuzzystringmatch hanami/mailer logger
  simple_args_dispatch simple_config_man simple_speaker sqlite3
).freeze

FULL_REQ = %w(
  active_support active_support/core_ext/object/deep_dup.rb active_support/core_ext/integer/time.rb active_support/inflector
  archive/zip base64 bencode deluge digest/md5 digest/sha1 eventmachine feedjira find flac2mp3 get_process_mem
  goodreads io/console imdb_party mechanize mediainfo mp3info net/ssh pdf/reader rsync shellwords socket
  streamio-ffmpeg timeout titleize themoviedb torznab trakt tvdb_party tvmaze unrar xbmc-client yaml
).freeze

# Helper method to require gems, with error handling
def require_gems(gem_list)
  gem_list.each do |gem_name|
    begin
      require gem_name
    rescue LoadError
      puts "You need to install the #{gem_name} gem by running `bundle install`"
      raise
    end
  end
end

# Load minimal requirements and files
require_gems(MIN_REQ)
Dir[File.join(File.dirname(__FILE__), 'min_lib', '*.rb')].each { |file| require file }

class Librarian
  attr_accessor :args, :quit, :reload

  # Global available actions used by the dispatching
  $available_actions = {
    help:             ['Librarian', 'help'],
    reconfigure:      ['Librarian', 'reconfigure'],
    daemon: {
      start:             ['Daemon', 'start'],
      status:            ['Daemon', 'status', 1, 'priority'],
      stop:              ['Daemon', 'stop', 1, 'priority'],
      reload:            ['Daemon', 'reload', 1, 'priority'],
      dump_bus_variable: ['BusVariable', 'display_bus_variable'],
      dump_mem_stat:     ['Memory', 'stat_dump'],
      kill_job:          ['Daemon', 'kill', 1, 'priority']
    },
    books: {
      compress_comics: ['Book', 'compress_comics'],
      convert_comics:  ['Library', 'convert_media']
    },
    library: {
      compare_remote_files:    ['Library', 'compare_remote_files'],
      create_custom_list:      ['Library', 'create_custom_list'],
      fetch_media_box:         ['Library', 'fetch_media_box'],
      get_media_list_size:     ['Library', 'get_media_list_size'],
      handle_completed_download: ['Library', 'handle_completed_download', 4, 'handle_completed_download', 1],
      process_folder:          ['Library', 'process_folder']
    },
    music: {
      create_playlists: ['Music', 'create_playlists'],
      convert_songs:    ['Library', 'convert_media']
    },
    torrent: {
      check_all_download:                  ['TorrentSearch', 'check_all_download', 1, 'torrenting'],
      check_orphaned_torrent_folders:        ['TorrentClient', 'check_orphaned_torrent_folders'],
      prevent_delete:                        ['TorrentClient', 'no_delete_torrent'],
      search:                                ['TorrentSearch', 'search_from_torrents']
    },
    usage:       ['Librarian', 'help'],
    list_db:     ['Utils', 'list_db'],
    flush_queues: ['TorrentClient', 'flush_queues', 1, 'torrenting'],
    monitor_torrent_client: ['TorrentClient', 'monitor_torrent_client', 1, 'torrenting'],
    cache_reset: ['Cache', 'cache_reset'],
    send_email:  ['Report', 'push_email'],
    test_childs: ['Librarian', 'test_childs', 1, 'test_childs', 1]
  }
  $debug_classes = []

  # Instance methods

  def initialize
    @args = ARGV
    # Require the main application file using require_relative for clarity
    require_relative 'init'
    @loaded = false
  end

  def daemonize
    Process.daemon
    exit if fork
    Process.setsid
    exit if fork
    Dir.chdir("/")
    suppress_output
  end

  def leave
    $speaker.speak_up("End of session, good bye...")
  end

  def loaded?
    @loaded
  end

  def write_pid
    begin
      File.open($pidfile, ::File::CREAT | ::File::EXCL | ::File::WRONLY) do |f|
        f.write("#{Process.pid}")
      end
      at_exit { File.delete($pidfile) if File.exists?($pidfile) }
    rescue Errno::EEXIST
      check_pid
      retry
    end
  end

  def check_pid
    case pid_status($pidfile)
    when :running, :not_owned
      $speaker.speak_up("A server is already running. Check #{$pidfile}")
      exit(1)
    when :dead
      delete_pid
    end
  end

  def delete_pid
    File.delete($pidfile)
  end

  def pid_status(pidfile)
    return :exited unless File.exists?(pidfile)
    pid = ::File.read(pidfile).to_i
    return :dead if pid.zero?
    Process.kill(0, pid) # Checks process status
    :running
  rescue Errno::ESRCH
    :dead
  rescue Errno::EPERM
    :not_owned
  end

  def quit?
    quit || reload
  end

  # Renamed from 'requirments' to 'load_requirements'
  def load_requirements
    require_gems(FULL_REQ)
    Dir[File.join(File.dirname(__FILE__), 'lib', '*.rb')].each { |file| require file }
    Dir[File.join(File.dirname(__FILE__), 'init', '*.rb')].each { |file| require file }
    @loaded = true
  end

  def run!
    trap_signals
    ExecutionHooks.on_the_fly_hooking($debug_classes)
    $speaker.speak_up("Welcome to your library assistant!\n\n")
    self.class.route_cmd(args)
  end

  def suppress_output
    $stderr.reopen('/dev/null', 'a')
    $stdout.reopen($stderr)
  end

  def trap_signals
    trap('QUIT') { @quit = true }  # graceful shutdown
  end

  # Class methods

  def self.burst_thread(tid = Daemon.job_id, client = nil, parent = nil, envf = Daemon.dump_env_flags, child = 0, queue_name = '', &block)
    Thread.new do
      $args_dispatch.set_env_variables($env_flags, envf)
      reset_notifications(Thread.current)
      Thread.current[:log_msg]   = '' if child.to_i > 0
      Thread.current[:current_daemon] = client || Thread.current[:current_daemon]
      Thread.current[:parent]    = parent
      Thread.current[:jid]       = tid
      Thread.current[:queue_name]= queue_name
      LibraryBus.initialize_queue(Thread.current)
      block.call
    end
  end

  def self.help
    $args_dispatch.show_available(APP_NAME, $available_actions)
  end

  def self.init_thread(thread, object = '', direct = 0, &block)
    reset_notifications(thread)
    thread[:object]     = object
    thread[:start_time] = Time.now
    thread[:direct]     = direct
    thread[:block]      = [block]
    thread[:is_active]  = 1
  end

  def self.reconfigure
    if Daemon.is_daemon?
      return $speaker.speak_up("Can not configure application when launched as a daemon")
    end
    SimpleConfigMan.reconfigure($config_file, $config_example)
  end

  def self.route_cmd(args, internal = 0, task = 'exclusive', max_pool_size = 1, queue = Thread.current[:jid], &block)
    if Daemon.is_daemon?
      Daemon.thread_cache_add(queue, args, Daemon.job_id, task, internal, max_pool_size, 0,
                              Daemon.fetch_function_config(args)[2] || 0,
                              Thread.current[:current_daemon], 43200, 1, &block)
    elsif $librarian.pid_status($pidfile) == :running && internal.to_i.zero?
      return if args.nil? || args.empty?
      $speaker.speak_up('A daemon is already running, sending execution there and waiting to get an execution slot')
      EventMachine.run do
        EventMachine.connect '127.0.0.1', $api_option['listen_port'], Client, args
        EM.open_keyboard(ClientInput)
      end
    else
      $librarian.load_requirements unless $librarian.loaded?
      LibraryBus.initialize_queue(Thread.current)
      run_command(args, internal)
    end
  end

  def self.reset_notifications(thread)
    thread[:email_msg]  = ''
    thread[:send_email] = 0
  end

  def self.run_command(cmd, direct = 0, object = '', &block)
    object = cmd[0..1].join(' ') if object.to_s.empty? || object == 'rcv'
    init_thread(Thread.current, object, direct, &block)

    thread_value =
      if direct.to_i > 0
        m = cmd.shift
        a = cmd.shift
        p = Object.const_get(m).method(a.to_sym)
        cmd.nil? ? p.call : p.call(*cmd)
      else
        $speaker.speak_up("Running command: ", 0)
        $speaker.speak_up("#{cmd.map { |a| a.gsub(/--?([^=\s]+)(?:=(.+))?/, '--\1=\'\2\'') }.join(' ')}\n\n", 0)
        $args_dispatch.dispatch(APP_NAME, cmd, $available_actions, nil, $template_dir)
      end

    run_termination(Thread.current, thread_value)
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    run_termination(Thread.current, thread_value, "Error on #{object}")
  end

  def self.run_termination(thread, thread_value, object = nil)
    thread[:end_time] = Time.now
    thread[:is_active] = 0
    Daemon.clear_waiting_worker(thread, thread_value, object)
    terminate_command(thread, thread_value, object)
  end

  def self.terminate_command(thread, thread_value = nil, object = nil)
    return unless thread[:base_thread].nil?
    return if Daemon.get_children_count(thread[:jid]).to_i > 0 || thread[:is_active] > 0

    LibraryBus.put_in_queue(thread_value)
    if thread[:direct].to_i.zero?
      elapsed_time = Time.now - thread[:start_time]
      time_info = TimeUtils.seconds_in_words(elapsed_time)
      lock_time   = Utils.lock_time_get(thread)
      $speaker.speak_up("Command '#{thread[:object]}' executed in #{time_info},#{lock_time}", 0, thread)
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

  def self.test_childs(how_many: 10000)
    (0...how_many.to_i).each do |i|
      Librarian.route_cmd(
        ['Librarian', 'da_child', i],
        1,
        "#{Thread.current[:object]}",
        6
      )
    end
    $speaker.speak_up("Finale result is #{Daemon.consolidate_children}")
  end

  def self.da_child(i = "")
    $speaker.speak_up("i is '#{i}'")
    1
  end
end

# Create and run the Librarian instance
$librarian = Librarian.new
arguments  = $librarian.args.dup
first_time = true

while ($librarian.reload && !Daemon.is_daemon?) || first_time
  first_time = false
  $librarian.args   = arguments.dup
  $librarian.reload = false
  $librarian.run!
end

$librarian.leave
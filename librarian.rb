MIN_REQ = %w(bundler/setup eventmachine fuzzystringmatch hanami/mailer logger simple_args_dispatch simple_config_man simple_speaker sqlite3
sys-filesystem)
FULL_REQ = %w(active_support active_support/core_ext/object/deep_dup.rb active_support/core_ext/integer/time.rb
active_support/inflector archive/zip base64 bencode deluge digest/md5 digest/sha1 eventmachine feedjira find goodreads io/console
imdb_party mechanize mp3info net/ssh pdf/reader rsync shellwords sys/filesystem titleize
trakt tvdb_party tvmaze unrar xbmc-client yaml)

MIN_REQ.each do |r|
  begin
    require r
  rescue LoadError
    puts "You need to install the #{r} gem by running `bundle install`"
    raise
  end
end

class Librarian
  attr_accessor :args, :quit, :reload

  $available_actions = {
      :help => ['Librarian', 'help'],
      :reconfigure => ['Librarian', 'reconfigure'],
      :daemon => {
          :start => ['Daemon', 'start'],
          :status => ['Daemon', 'status'],
          :stop => ['Daemon', 'stop'],
          :reload => ['Daemon', 'reload']
      },
      :books => {
          :compress_comics => ['Book', 'compress_comics'],
          :convert_comics => ['Book', 'convert_comics'],
      },
      :library => {
          :compare_remote_files => ['Library', 'compare_remote_files'],
          :copy_media_from_list => ['Library', 'copy_media_from_list'],
          :copy_trakt_list => ['Library', 'copy_trakt_list'],
          :create_custom_list => ['Library', 'create_custom_list'],
          :fetch_media_box => ['Library', 'fetch_media_box'],
          :get_media_list_size => ['Library', 'get_media_list_size'],
          :handle_completed_download => ['Library', 'handle_completed_download'],
          :process_folder => ['Library', 'process_folder']
      },
      :music => {
          :create_playlists => ['Muic', 'create_playlists'],
      },
      :torrent => {
          :check_all_download => ['TorrentSearch', 'check_all_download'],
          :search => ['TorrentSearch', 'search_from_torrents']
      },
      :trakt => {
          :refresh_auth => ['TraktAgent', 'refresh_auth']
      },
      :usage => ['Librarian', 'help'],
      :list_db => ['Utils', 'list_db'],
      :flush_queues => ['Librarian', 'flush_queues'],
      :forget => ['Utils', 'forget'],
      :send_email => ['Report', 'push_email']
  }

  def initialize
    @args = ARGV
    @loaded = false
    #Require libraries
    Dir[File.dirname(__FILE__) + '/lib/*.rb'].each { |file| require file }
    #Require app file
    require File.dirname(__FILE__) + '/init.rb'
  end

  def daemonize
    Process.daemon
    exit if fork
    Process.setsid
    exit if fork
    Dir.chdir "/"
    suppress_output
  end

  def leave
    $speaker.speak_up("End of session, good bye...")
  end

  def loaded
    @loaded
  end

  def write_pid
    begin
      File.open($pidfile, ::File::CREAT | ::File::EXCL | ::File::WRONLY) { |f| f.write("#{Process.pid}") }
      at_exit { File.delete($pidfile) if File.exists?($pidfile) }
    rescue Errno::EEXIST
      check_pid
      retry
    end
  end

  def check_pid
    case pid_status($pidfile)
      when :running, :not_owned
        $speaker.speak_up "A server is already running. Check #{$pidfile}"
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
    return :dead if pid == 0
    Process.kill(0, pid) # check process status
    :running
  rescue Errno::ESRCH
    :dead
  rescue Errno::EPERM
    :not_owned
  end

  def quit?
    quit || reload
  end

  def requirments
    FULL_REQ.each do |r|
      begin
        require r
      rescue LoadError
        puts "You need to install the #{r} gem by running `bundle install`"
        raise
      end
    end
    Dir[File.dirname(__FILE__) + '/init/*.rb'].each { |file| require file }
    @loaded = true
  end

  def run!
    trap_signals
    $speaker.speak_up("Welcome to your library assistant!\n\n")
    Librarian.route_cmd(args)
  end

  def suppress_output
    $stderr.reopen('/dev/null', 'a')
    $stdout.reopen($stderr)
  end

  def trap_signals
    trap('QUIT') do # graceful shutdown
      @quit = true
    end
  end

  def self.burst_thread(client = nil, parent = nil, envf = Daemon.dump_env_flags, child = 0, &block)
    t = Thread.new do
      $args_dispatch.set_env_variables($env_flags, envf)
      reset_notifications(t)
      t[:log_msg] = '' if child.to_i > 0
      t[:current_daemon] = client || Thread.current[:current_daemon]
      t[:parent] = parent
      block.call
    end
    t
  end

  def self.flush_queues
    if $t_client
      $t_client.parse_torrents_to_download
      sleep 15
      $t_client.process_added_torrents
      $t_client.disconnect
    end
    #Cleanup lists and folders
    FileUtils.cleanup_folder unless Cache.queue_state_get('dir_to_delete').empty?
    TraktAgent.clean_list(Cache.queue_state_get('cleanup_trakt_list')) unless Cache.queue_state_get('cleanup_trakt_list').empty?
  end

  def self.help
    $args_dispatch.show_available(APP_NAME, $available_actions)
  end

  def self.init_thread(t, object = '', direct = 0, &block)
    reset_notifications(t)
    t[:object] = object
    t[:start_time] = Time.now
    t[:direct] = direct
    t[:block] = block
  end

  def self.reconfigure
    return $speaker.speak_up "Can not configure application when launched as a daemon" if Daemon.is_daemon?
    SimpleConfigMan.reconfigure($config_file, $config_example)
  end

  def self.route_cmd(args, internal = 0, queue = 'exclusive', &block)
    r = 0
    if Daemon.is_daemon?
      r = Daemon.thread_cache_add(queue, args, Daemon.job_id, queue, internal, 0, 0, Thread.current[:current_daemon], 43200, 1, &block)
    elsif $librarian.pid_status($pidfile) == :running
      return if args.nil? || args.empty?
      $speaker.speak_up 'A daemon is already running, sending execution there and waiting to get an execution slot'
      EventMachine.run do
        EventMachine.connect '127.0.0.1', $api_option['listen_port'], Client, args
        EM.open_keyboard(ClientInput)
      end
    else
      $librarian.requirments unless $librarian.loaded
      run_command(args, internal)
      Librarian.flush_queues if internal.to_i == 0
    end
    r
  end

  def self.reset_notifications(t)
    t[:email_msg] = ''
    t[:send_email] = 0
  end

  def self.run_command(cmd, direct = 0, object = '', &block)
    object = cmd[0..1].join(' ') if object == 'rcv' || object.to_s == ''
    init_thread(Thread.current, object, direct, &block)
    if direct.to_i > 0
      m = cmd.shift
      a = cmd.shift
      p = Object.const_get(m).method(a.to_sym)
      cmd.nil? ? p.call : p.call(*cmd)
    else
      $speaker.speak_up("Running command: #{cmd.map { |a| a.gsub(/--?([^=\s]+)(?:=(.+))?/, '--\1=\'\2\'') }.join(' ')}\n\n", 0)
      $args_dispatch.dispatch(APP_NAME, cmd, $available_actions, nil, $template_dir)
    end
    terminate_command(Thread.current)
  rescue => e
    $speaker.tell_error(e, "Librarian.run_command(#{object}")
    terminate_command(Thread.current, "Error on #{object}")
  end

  def self.terminate_command(thread, object = nil)
    return unless thread[:base_thread].nil?
    return if thread[:childs].to_i > 0
    if thread[:direct].to_i == 0 || Env.debug?
      $speaker.speak_up("Command '#{thread[:object]}' executed in #{(Time.now - thread[:start_time])} seconds", 0, thread)
      Report.sent_out("#{'[DEBUG]' if Env.debug?}#{object || thread[:object]}", thread) if Env.email_notif? && thread[:direct].to_i == 0
    end
    thread[:block].call if thread[:block]
    if thread[:parent]
      Utils.lock_block("merge_child_thread#{thread[:object]}") {
        Daemon.merge_notifications(thread, thread[:parent])
        Daemon.decremente_children(thread[:parent])
        terminate_command(thread[:parent], object)
      }
    end
  end
end

$librarian = Librarian.new
arguments = $librarian.args.dup
first_time = true
while ($librarian.reload && !Daemon.is_daemon?) || first_time
  first_time = false
  $librarian.args = arguments.dup
  $librarian.reload = false
  $librarian.run!
end
$librarian.leave
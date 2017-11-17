REQ = %w(archive/zip bundler/setup active_support/time base64 bencode deluge digest/md5 digest/sha1 eventmachine find
fuzzystringmatch hanami/mailer io/console imdb_party json logger mechanize mp3info net/ssh pdf/reader rarbg rsync rubygems
shellwords simple_args_dispatch simple_config_man simple-rss sqlite3 sys/filesystem titleize trakt tvdb_party tvmaze unrar
xbmc-client yaml)

REQ.each do |r|
  begin
    require r
  rescue LoadError
    puts "You need to install the #{r} gem by running `bundle install`"
    raise
  end
end

class Librarian
  attr_accessor :args, :quit

  $available_actions = {
      :help => ['Librarian', 'help'],
      :reconfigure => ['Librarian', 'reconfigure'],
      :daemon => {
          :start => ['Daemon', 'start'],
          :stop => ['Daemon', 'stop'],
      },
      :ebooks => {
          :compress_comics => ['Ebooks', 'compress_comics'],
          :convert_comics => ['Ebooks', 'convert_comics'],
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
          :refresh_auth => ['TraktList', 'refresh_auth']
      },
      :usage => ['Librarian', 'help'],
      :flush_queues => ['Librarian', 'flush_queues'],
      :send_email => ['Report', 'push_email']
  }

  def initialize
    @args = ARGV
    #Require libraries
    Dir[File.dirname(__FILE__) + '/lib/*.rb'].each { |file| require file }
    #Require app file
    require File.dirname(__FILE__) + '/init.rb'
    Dir[File.dirname(__FILE__) + '/init/*.rb'].each { |file| require file }
  end

  def daemonize
    Process.daemon
    exit if fork
    Process.setsid
    exit if fork
    Dir.chdir "/"
    suppress_output
  end

  def run!
    trap_signals
    $speaker.speak_up("Welcome to your library assistant!\n\n")
    Librarian.route_cmd(args)
  end

  def leave
    $speaker.speak_up("End of session, good bye...")
  end

  def self.reconfigure
    return $speaker.speak_up "Can not configure application when launched as a daemon" if Daemon.is_daemon?
    SimpleConfigMan.reconfigure($config_file, $config_example)
  end

  def self.help
    $args_dispatch.show_available(APP_NAME, $available_actions)
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
        File.delete($pidfile)
    end
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

  def suppress_output
    $stderr.reopen('/dev/null', 'a')
    $stdout.reopen($stderr)
  end

  def trap_signals
    trap('QUIT') do # graceful shutdown
      @quit = true
    end
  end

  def self.flush_queues
    if $t_client
      $t_client.process_download_torrents
      $t_client.process_added_torrents
      while Find.find($temp_dir).count > 1
        $speaker.speak_up('Waiting for temporary folder to be cleaned')
        sleep 10
        Utils.queue_state_get('deluge_torrents_added').select { |_, v| v < 2 }.each do |k, _|
          Utils.queue_state_add_or_update('deluge_torrents_added', {k => 2})
        end
        $t_client.process_added_torrents
      end
      unless Utils.queue_state_get('deluge_options').empty?
        $speaker.speak_up('Waiting for completion of all deluge operation')
        sleep 15
        $t_client.process_added_torrents
      end
      Utils.cleanup_folder unless Utils.queue_state_get('dir_to_delete').empty?
      $t_client.disconnect
    end
    #Cleanup list
    TraktList.clean_list('watchlist') unless Utils.queue_state_get('cleanup_trakt_list').empty?
  end

  def self.route_cmd(args, internal = 0, queue = 'exclusive')
    if Daemon.is_daemon?
      Daemon.thread_cache_add(queue, args, Daemon.job_id, 'direct', 0, internal)
    elsif $librarian.pid_status($pidfile) == :running
      return if args.nil? || args.empty?
      $speaker.speak_up 'A daemon is already running, sending execution there'
      EventMachine.run do
        EventMachine.connect '127.0.0.1', $api_option['listen_port'], Client, args
        EM.open_keyboard(ClientInput)
      end
    else
      run_command(args, internal)
      Librarian.flush_queues
    end
  end

  def self.run_command(cmd, direct = 0, queue = 'exclusive')
    start = Time.now
    Thread.current[:email_msg] = ''
    Thread.current[:send_email] = 0
    $speaker.speak_up("Running command: #{cmd.map { |a| a.gsub(/--?([^=\s]+)(?:=(.+))?/, '--\1=\'\2\'') }.join(' ')}\n\n", 0)
    $action = cmd[0].to_s + ' ' + cmd[1].to_s
    if direct.to_i > 0
      m = cmd.shift
      a = cmd.shift
      p = Object.const_get(m).method(a.to_sym)
      cmd.nil? ? p.call : p.call(*cmd)
    else
      $args_dispatch.dispatch(APP_NAME, cmd, $available_actions, nil, $template_dir)
    end
    Report.sent_out($action, Thread.current[:email_msg]) if $action && Env.email_notif?
    $speaker.speak_up("Command executed in #{(Time.now - start)} seconds", 0)
  rescue => e
    $speaker.tell_error(e, "Librarian.run_command(#{cmd}")
  end

  def self.burst_thread(&block)
    t = Thread.new { block.call }
    t[:debug] = Thread.current[:debug].to_i
    t[:no_email_notif] = Thread.current[:no_email_notif].to_i
    t[:pretend] = Thread.current[:pretend].to_i
    t
  end
end

$librarian = Librarian.new
$librarian.run!
$librarian.leave
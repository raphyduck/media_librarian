REQ = %w(archive/zip bundler/setup active_support/time base64 bencode deluge digest/md5 digest/sha1 find
fuzzystringmatch hanami/mailer io/console imdb_party json logger mechanize mp3info net/ssh pdf/reader rarbg rsync rubygems
shellwords simple_args_dispatch simple_config_man simple_speaker sqlite3 sys/filesystem titleize trakt tvdb_party tvmaze unrar
xbmc-client yaml)

REQ.each do |r|
  begin
    require r
  rescue LoadError
    puts "You need to install the #{r} gem"
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
          :process_download_list => ['Library', 'process_download_list'],
          :process_folder => ['Library', 'process_folder']
      },
      :music => {
          :create_playlists => ['Muic', 'create_playlists'],
      },
      :torrent => {
          :search => ['TorrentSearch', 'search'],
          :random_pick => ['TorrentSearch', 'random_pick']
      },
      :usage => ['Librarian', 'help']
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

  def flush_queues
    if $t_client
      $t_client.process_download_torrents
      $t_client.process_added_torrents
      while Find.find($temp_dir).count > 1
        $speaker.speak_up('Waiting for temporary folder to be cleaned')
        sleep 10
        $deluge_torrents_added = ($deluge_torrents_added + $deluge_torrents_preadded).uniq
        $t_client.process_added_torrents
      end
      if !$deluge_options.empty?
        $speaker.speak_up('Waiting for completion of all deluge operation')
        sleep 15
        $t_client.process_added_torrents
      end
      Utils.cleanup_folder unless $dir_to_delete.empty?
      $t_client.disconnect
    end
    #Cleanup list
    TraktList.clean_list('watchlist') unless $cleanup_trakt_list.empty?
  end

  def run!
    trap_signals
    $speaker.speak_up("Welcome to your library assistant!\n\n")
    $speaker.speak_up("Running command: #{args.map { |a| a.gsub(/--?([^=\s]+)(?:=(.+))?/, '--\1=\'\2\'') }.join(' ')}\n\n")
    $action = args[0].to_s + ' ' + args[1].to_s
    SimpleArgsDispatch.dispatch(APP_NAME, args, $available_actions, nil, $template_dir)
  end

  def leave
    Report.sent_out($action) if $action && $env_flags['no_email_notif'].to_i == 0
    $speaker.speak_up("End of session, good bye...")
  end

  def self.reconfigure
    SimpleConfigMan.reconfigure($config_file, $config_example)
  end

  def self.help
    $speaker.speak_up('Showing help')
    SimpleArgsDispatch.show_available(APP_NAME, $available_actions)
  end

  def write_pid
      begin
        File.open($pidfile, ::File::CREAT | ::File::EXCL | ::File::WRONLY){|f| f.write("#{Process.pid}") }
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
    Process.kill(0, pid)      # check process status
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
    trap('QUIT') do   # graceful shutdown
      @quit = true
    end
  end
end

$librarian = Librarian.new
$librarian.run!
$librarian.leave
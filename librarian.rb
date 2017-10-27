require 'archive/zip'
require 'bundler/setup'
require 'active_support/time'
require 'base64'
require 'bencode'
require 'deluge'
require 'digest/md5'
require 'digest/sha1'
require 'find'
require 'fuzzystringmatch'
require 'hanami/mailer'
require 'io/console'
require 'imdb'
require 'json'
require 'logger'
require 'mechanize'
require 'mp3info'
require 'net/ssh'
require 'pdf/reader'
require 'rarbg'
require 'rsync'
require 'rubygems'
require 'shellwords'
require 'simple_args_dispatch'
require 'simple_config_man'
require 'simple_speaker'
require 'sqlite3'
require 'sys/filesystem'
require 'titleize'
require 'trakt'
require 'tvdb_party'
require 'tvmaze'
require 'unrar'
require 'xbmc-client'
require 'yaml'
#Process.daemon

class Librarian

  @available_actions = {
      :help => ['Librarian', 'help'],
      :reconfigure => ['Librarian', 'reconfigure'],
      :library => {
          :compare_remote_files => ['Library', 'compare_remote_files'],
          :compress_comics => ['Library', 'compress_comics'],
          :convert_comics => ['Library', 'convert_comics'],
          :copy_media_from_list => ['Library', 'copy_media_from_list'],
          :copy_trakt_list => ['Library', 'copy_trakt_list'],
          :create_playlists => ['Library', 'create_playlists'],
          :create_custom_list => ['Library', 'create_custom_list'],
          :fetch_media_box => ['Library', 'fetch_media_box'],
          :get_media_list_size => ['Library', 'get_media_list_size'],
          :handle_completed_download => ['Library', 'handle_completed_download'],
          :monitor_tv_episodes => ['Library', 'monitor_tv_episodes'],
          :process_search_list => ['Library', 'process_search_list'],
          :rename_tv_series => ['Library', 'rename_tv_series'],
          :replace_movies => ['Library', 'replace_movies']
      },
      :torrent => {
          :search => ['TorrentSearch', 'search'],
          :random_pick => ['TorrentSearch', 'random_pick']
      },
      :usage => ['Librarian', 'help']
  }

  def initialize
    #Require libraries
    Dir[File.dirname(__FILE__) + '/lib/*.rb'].each {|file| require file }
    #Require app file
    require File.dirname(__FILE__) + '/init.rb'
    Dir[File.dirname(__FILE__) + '/init/*.rb'].each {|file| require file }
  end

  def self.run
    $speaker.speak_up("Welcome to your library assistant!\n\n")
    $speaker.speak_up("Running command: #{ARGV.map{|a| a.gsub(/--?([^=\s]+)(?:=(.+))?/,'--\1=\'\2\'')}.join(' ')}\n\n")
    $action = ARGV[0].to_s + ' ' + ARGV[1].to_s
    SimpleArgsDispatch.dispatch('librarian', ARGV, @available_actions, nil, $template_dir)
  end

  def self.leave
    if $t_client
      $t_client.process_download_torrents
      #Cleanup list
      TraktList.clean_list('watchlist') unless $cleanup_trakt_list.empty?
      Utils.cleanup_folder unless $dir_to_delete.empty?
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
      $t_client.disconnect
    end
    Report.deliver(object_s: $action + ' - ' + Time.now.strftime("%a %d %b %Y").to_s) if $email && $action && $email_msg && $env_flags['no_email_notif'].to_i == 0
    $speaker.speak_up("End of session, good bye...")
  end

  def self.reconfigure
    SimpleConfigMan.reconfigure($config_file, $config_example)
  end

  def self.help
    SimpleArgsDispatch.show_available('librarian', @available_actions)
  end
end

Librarian.new
Librarian.run
Librarian.leave
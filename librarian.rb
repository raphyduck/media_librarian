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
require 'rsync'
require 'rubygems'
require 'shellwords'
require 'sqlite3'
require 'sys/filesystem'
require 't411'
require 'trakt'
require 'tvmaze'
require 'xbmc-client'
require 'yaml'
require 'zipruby'
#Process.daemon

class Librarian

  def initialize
    #Require libraries
    Dir[File.dirname(__FILE__) + '/lib/*.rb'].each {|file| require file }
    #Require app file
    require File.dirname(__FILE__) + '/init.rb'
  end

  def self.run
    Speaker.speak_up('Welcome to your library assistant!

')
    Dispatcher.dispatch(ARGV)
  end

  def self.leave
    if $t_client
      $t_client.process_download_torrents
      $t_client.process_added_torrents
      while Find.find($temp_dir).count > 1
        Speaker.speak_up('Waiting for temporary folder to be cleaned')
        sleep 10
        $deluge_torrents_added = ($deluge_torrents_added + $deluge_torrents_preadded).uniq
        $t_client.process_added_torrents
      end
      if !$deluge_options.empty?
        Speaker.speak_up('Waiting for completion of all deluge operation')
        sleep 15
        $t_client.process_added_torrents
      end
      $t_client.disconnect
    end
    TraktList.clean_list('watchlist') unless $cleanup_trakt_list.empty?
    Utils.cleanup_folder unless $dir_to_delete.empty?
    Report.deliver(object_s: $action + ' - ' + Time.now.strftime("%a %d %b %Y").to_s) if $email && $action && $email_msg
    Speaker.speak_up("End of session, good bye...")
  end
end

Librarian.new
Librarian.run
Librarian.leave
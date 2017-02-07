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
require 'net/ssh'
require 'rsync'
require 'rubygems'
require 'sqlite3'
require 'sys/filesystem'
require 't411'
require 'trakt'
require 'tvmaze'
require 'xbmc-client'
require 'yaml'
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
        $t_client.process_added_torrents
        sleep 5
      end
      while !$deluge_options.empty?
        Speaker.speak_up('Waiting for completion of all deluge operation')
        $t_client.process_added_torrents
        sleep 5
      end
      $t_client.disconnect
    end
    Report.deliver(object_s: $action) if $email
    Speaker.speak_up("End of session, good bye...")
  end
end

Librarian.new
Librarian.run
Librarian.leave
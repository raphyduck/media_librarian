require 'active_support/time'
require 'yaml'
require 'find'
require 'base64'
require 'rubygems'
require 'bundler/setup'
require 'logger'
require 'io/console'
require 't411'
require 'imdb'
require 'deluge'
require 'json'
require 'fuzzystringmatch'
#Process.daemon

class Librarian

  def initialize
    #Require app file
    require File.dirname(__FILE__) + '/init.rb'
  end

  def self.run
    Speaker.speak_up('Welcome')
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
  end
end

Librarian.new
Librarian.run
Librarian.leave
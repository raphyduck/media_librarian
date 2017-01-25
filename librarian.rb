require 'yaml'
require 'find'
require 'base64'
require 'rubygems'
require 'bundler/setup'
require 'logger'
require 'io/console'
require 't411'
require 'deluge'
require 'json'
#Process.daemon

class Librarian

  def initialize
    #Require app file
    require File.dirname(__FILE__) + '/init.rb'
    $logger = Logger.new($log_dir + '/medialibrarian.log')
    $logger_error = Logger.new($log_dir + '/medialibrarian_errors.log')
  end

  def self.run
    Speaker.speak_up('Starting')
    Dispatcher.dispatch(ARGV)
  end

  def self.leave
    while Find.find($temp_dir).count > 1
      Speaker.speak_up('Waiting for temporary folder to be cleaned')
      sleep 5
    end
    $t_client.disconnect
  end
end

Librarian.new
Librarian.run
Librarian.leave
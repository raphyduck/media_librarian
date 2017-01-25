#!/usr/local/bin/ruby

# Example application to demonstrate some basic Ruby features
# This code loads a given file into an associated application

require 'yaml'
#Require bundle and gems management
require 'rubygems'
require 'bundler/setup'
require 'logger'
require 'io/console'
require 't411'
#Process.daemon
require File.dirname(__FILE__) + '/init.rb'

class Librarian

  def initialize
    #Require app file
    Dir[File.dirname(__FILE__) + '/app/*.rb'].each {|file| require file }
    Dir.mkdir($config_dir) unless File.exist?($config_dir)
    Dir.mkdir($log_dir) unless File.exist?($log_dir)
    $logger = Logger.new($log_dir + '/medialibrarian.log')
    $logger_error = Logger.new($log_dir + '/medialibrarian_errors.log')
    Librarian.load_settings
  end

  def self.run
    $logger.info("Starting")
  end

  def self.load_settings
    configs = nil
    Dir.mkdir($config_dir) unless File.exist?($config_dir)
    unless File.exist?($config_file)
      FileUtils.copy File.dirname(__FILE__) + '/config/conf.yml.example', $config_file
      configs = YAML.load_file($config_file)
      #Let's set the first config
      puts 'The configuration file needs to be initialized.'
      puts 'Do you want to say T411 authentication? (y/n)'
      reply = gets.strip
      if reply == 'y'
        configs['t411'] = {} unless configs['t411']
        Speaker.speak_up 'What is your t411 username? '
        configs['t411']['username'] = gets.strip
        configs['t411']['password'] = STDIN.getpass('What is your t411 password? ')
      else
        configs.delete('t411')
      end
      Speaker.speak_up 'All set!'
      File.write($config_file, YAML.dump(configs))
    end
    configs = YAML.load_file($config_file) unless configs
    if configs['t411']
      T411.authenticate(configs['t411']['username'], configs['t411']['password'])
      Speaker.speak_up("You are #{T411.authenticated? ? 'now' : 'NOT'} connected to T411")
    end
  end
end

Librarian.new
Librarian.run
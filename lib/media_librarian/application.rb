require 'bundler/setup'
require 'zeitwerk'
require 'fileutils'
require_relative 'container'

module MediaLibrarian
  APP_NAME = 'librarian'.freeze

  class Application
    attr_reader :root,
                :env_flags,
                :config_dir,
                :config_file,
                :config_example,
                :temp_dir,
                :template_dir,
                :tracker_dir,
                :pid_dir,
                :pidfile,
                :loader,
                :container

    attr_accessor :daemon_client,
                  :email,
                  :email_templates,
                  :ffmpeg_crf,
                  :ffmpeg_preset,
                  :kodi,
                  :mechanizer,
                  :tvdb,
                  :deluge_connected,
                  :t_client,
                  :remove_torrent_on_completion,
                  :trakt_account,
                  :trakt,
                  :librarian

    def initialize(root: File.expand_path('../..', __dir__))
      @root = root
      @daemon_client = nil
      setup_dependencies
      setup_loader
      setup_environment
      @container = Container.new(self)
    end

    def config
      container.config
    end

    def speaker
      container.speaker
    end

    def speaker=(value)
      container.speaker = value
    end

    def args_dispatch
      container.args_dispatch
    end

    def api_option
      container.api_option
    end

    def workers_pool_size
      container.workers_pool_size
    end

    def queue_slots
      container.queue_slots
    end

    def db
      container.db
    end

    def db=(value)
      container.db = value
    end

    def trackers
      container.trackers
    end

    def trackers=(value)
      container.trackers = value
    end

    def str_closeness
      container.str_closeness
    end

    def str_closeness=(value)
      container.str_closeness = value
    end

    def tracker_client
      container.tracker_client
    end

    def tracker_client=(value)
      container.tracker_client = value
    end

    def tracker_client_last_login
      container.tracker_client_last_login
    end

    def tracker_client_last_login=(value)
      container.tracker_client_last_login = value
    end

    private

    def setup_dependencies
      Bundler.require(:default)
    end

    def setup_loader
      @loader = Zeitwerk::Loader.new
      @loader.push_dir(File.join(root, 'app'))
      @loader.push_dir(File.join(root, 'lib'))
      @loader.push_dir(File.join(root, 'min_lib'))
      @loader.ignore(__FILE__)
      register_loader_hooks
      @loader.setup
    end

    def setup_environment
      @env_flags = {
        debug: 0,
        no_email_notif: 0,
        pretend: 0,
        expiration_period: 0
      }

      @config_dir = File.join(Dir.home, '.medialibrarian')
      @config_file = File.join(@config_dir, 'conf.yml')
      @config_example = File.join(root, 'config', 'conf.yml.example')
      @temp_dir = File.join(@config_dir, 'tmp')
      @template_dir = File.join(@config_dir, 'templates')
      @tracker_dir = File.join(@config_dir, 'trackers')
      @pid_dir = File.join(@config_dir, 'pids')
      @pidfile = File.join(@pid_dir, 'pid.file')

      FileUtils.mkdir_p(@config_dir)
      FileUtils.mkdir_p(@temp_dir)
      FileUtils.mkdir_p(@pid_dir)

      unless File.exist?(@template_dir)
        FileUtils.cp_r(File.join(root, 'config', 'templates/'), @template_dir)
      end

      FileUtils.mkdir_p(File.join(@config_dir, 'log'))
    end

    def register_loader_hooks
      return unless defined?(@loader)

      register = lambda do |const|
        @loader.on_load(const) do |klass|
          klass.configure(app: self) if klass.respond_to?(:configure)
        end
      end

      %w[
        MoviesSet
        Movie
        TvSeries
        Report
        Daemon
        TorrentSearch
        TorrentClient
        Client
        Library
      ].each { |const| register.call(const) }
    end
  end

  class << self
    attr_writer :application

    def application
      @application ||= Application.new
    end

    alias_method :app, :application
  end
end

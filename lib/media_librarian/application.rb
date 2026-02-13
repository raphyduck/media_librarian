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
                :api_config_file,
                :api_config_example,
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

    def inspect
      "#<#{self.class.name} root=#{@root.inspect}>"
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

    def api_option=(value)
      container.api_option = value
    end

    def workers_pool_size
      container.workers_pool_size
    end

    def queue_slots
      container.queue_slots
    end

    def finished_jobs_per_queue
      container.finished_jobs_per_queue
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
      require 'tvmaze' unless defined?(TVMaze::Show)
      require 'fuzzystringmatch' unless defined?(FuzzyStringMatch)
      require 'mechanize' unless defined?(Mechanize)
      require 'deluge/rpc' unless defined?(Deluge::Rpc::Client)
      require 'mediainfo' unless defined?(MediaInfo)
      require_relative '../http_debug_logger'
      Numeric.class_eval do
        time_units = {
          second: 1,
          minute: 60,
          hour: 3_600,
          day: 86_400,
          week: 604_800,
          month: 2_592_000,
          year: 31_536_000
        }

        time_units.each do |unit, multiplier|
          define_method(unit) do
            self * multiplier
          end unless method_defined?(unit)

          plural = "#{unit}s".to_sym
          alias_method plural, unit unless method_defined?(plural)
        end
      end
      require_relative '../hash'
      require_relative '../array'
      require_relative '../file_utils'
      load File.expand_path('../simple_speaker.rb', __dir__)
    end

    def setup_loader
      @loader = Zeitwerk::Loader.new
      @loader.push_dir(File.join(root, 'app'))
      @loader.push_dir(File.join(root, 'lib'))
      @loader.push_dir(File.join(root, 'min_lib'))
      @loader.ignore(__FILE__)
      @loader.ignore(File.join(root, 'lib', 'db', 'migrations'))
      register_loader_hooks
      @loader.setup
    end

    def setup_environment
      mkdir_p = if FileUtils.respond_to?(:mkdir_p_orig)
                  FileUtils.method(:mkdir_p_orig)
                else
                  FileUtils.method(:mkdir_p)
                end

      @env_flags = {
        debug: 0,
        no_email_notif: 0,
        pretend: 0,
        expiration_period: 0
      }

      @config_dir = File.join(Dir.home, '.medialibrarian')
      @config_file = File.join(@config_dir, 'conf.yml')
      @config_example = File.join(root, 'config', 'conf.yml.example')
      @api_config_file = File.join(@config_dir, 'api.yml')
      @api_config_example = File.join(root, 'config', 'api.yml.example')
      @temp_dir = File.join(@config_dir, 'tmp')
      @template_dir = File.join(@config_dir, 'templates')
      @tracker_dir = File.join(@config_dir, 'trackers')
      @pid_dir = File.join(@config_dir, 'pids')
      @pidfile = File.join(@pid_dir, 'pid.file')

      mkdir_p.call(@config_dir)
      mkdir_p.call(@temp_dir)
      mkdir_p.call(@pid_dir)

      unless File.exist?(@template_dir)
        FileUtils.cp_r(File.join(root, 'config', 'templates/'), @template_dir)
      end

      mkdir_p.call(File.join(@config_dir, 'log'))
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

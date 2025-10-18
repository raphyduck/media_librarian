require 'bundler/setup'
require 'zeitwerk'
require 'fileutils'

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
                :speaker,
                :args_dispatch,
                :config,
                :api_option,
                :workers_pool_size,
                :queue_slots,
                :loader

    attr_accessor :daemon_client,
                  :db,
                  :calibre,
                  :email,
                  :email_templates,
                  :ffmpeg_crf,
                  :ffmpeg_preset,
                  :goodreads,
                  :kodi,
                  :mechanizer,
                  :tvdb,
                  :deluge_connected,
                  :t_client,
                  :remove_torrent_on_completion,
                  :trakt_account,
                  :trakt,
                  :trackers,
                  :librarian,
                  :str_closeness,
                  :tracker_client,
                  :tracker_client_last_login

    def initialize(root: File.expand_path('../..', __dir__))
      @root = root
      @daemon_client = nil
      setup_dependencies
      setup_loader
      setup_environment
      setup_configuration
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

      @speaker = SimpleSpeaker::Speaker.new
      @args_dispatch = SimpleArgsDispatch::Agent.new(@speaker, @env_flags)
    end

    def setup_configuration
      @config = SimpleConfigMan.load_settings(@config_dir, @config_file, @config_example)
      @api_option = {
        'bind_address' => '127.0.0.1',
        'listen_port' => '8888'
      }
      @workers_pool_size = (@config['daemon'] && @config['daemon']['workers_pool_size']) || 4
      @queue_slots = (@config['daemon'] && @config['daemon']['queue_slots']) || 4
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

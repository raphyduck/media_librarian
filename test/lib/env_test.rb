# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'

class EnvTest < Minitest::Test
  def setup
    @env_module = Module.new
    env_path = File.expand_path('../../lib/env.rb', __dir__)
    @env_module.module_eval(File.read(env_path), env_path, 1)
    @home_dir = Dir.mktmpdir('medialibrarian-home')
    @app = nil
  end

  def teardown
    Thread.current[:no_email_notif] = nil
    @app&.loader&.unload
    MediaLibrarian.application = nil
    FileUtils.remove_entry(@home_dir) if @home_dir && Dir.exist?(@home_dir)
  end

  def test_email_notifications_enabled_by_default
    prepare_application

    assert env_class.email_notif?, 'Email notifications should be enabled by default'
  end

  def test_email_notifications_disable_when_flagged
    prepare_application

    MediaLibrarian.application.args_dispatch.set_env_variables(
      MediaLibrarian.application.env_flags,
      'no_email_notif' => '1'
    )

    refute env_class.email_notif?, 'Email notifications should be disabled when flag is set'
  ensure
    Thread.current[:no_email_notif] = nil
  end

  def test_env_constant_available_after_requiring_librarian
    result = nil

    Bundler.with_unbundled_env do
      Dir.chdir(File.expand_path('../..', __dir__)) do
        result = system('bundle', 'exec', 'ruby', '-r./librarian', '-e', 'Env')
      end
    end

    assert result, 'Env constant should load when requiring librarian'
  end

  private

  def env_class
    @env_module.const_get(:Env)
  end

  def prepare_application
    Dir.stub(:home, @home_dir) do
      Zeitwerk::Loader.stub(:new, NullLoader.new) do
        @app = MediaLibrarian::Application.new
      end
    end
    MediaLibrarian.application = @app
  end

  class NullLoader
    def push_dir(*) ; end

    def ignore(*) ; end

    def setup ; end

    def on_load(*)
      yield(nil) if block_given?
    end

    def unload ; end
  end
end

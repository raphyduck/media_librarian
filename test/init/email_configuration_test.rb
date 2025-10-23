# frozen_string_literal: true

require 'test_helper'
require 'hanami/mailer'

class EmailConfigurationTest < Minitest::Test
  def setup
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    env = @environment
    @environment.application.define_singleton_method(:config) { env.container.config }

    email_settings = SimpleConfigMan::DEFAULT_SETTINGS.merge(
      'email' => {
        'host' => 'smtp.gmail.com',
        'port' => 587,
        'domain' => '',
        'username' => 'user@example.com',
        'password' => 'secret',
        'auth_type' => ' plain '
      }
    )

    @environment.container.config = email_settings
    reset_librarian_state!
  end

  def teardown
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def test_configures_smtp_delivery_with_symbol_authentication
    captured = {}

    Hanami::Mailer.stub(:configure, lambda do |&block|
      fake_config = Object.new
      fake_config.define_singleton_method(:root) { |value| captured[:root] = value }
      fake_config.define_singleton_method(:delivery_method) do |method, settings = {}|
        captured[:delivery_method] = method
        captured[:settings] = settings
      end
      fake_config.define_singleton_method(:load!) { captured[:loaded] = true }
      fake_config.instance_eval(&block)
      fake_config
    end) do
      load File.expand_path('../../init/email.rb', __dir__)
    end

    expected_root = File.expand_path('../../app/mailer_templates', __dir__)
    assert_equal expected_root, captured[:root]
    assert_equal :smtp, captured[:delivery_method]

    expected_settings = {
      address: 'smtp.gmail.com',
      port: 587,
      user_name: 'user@example.com',
      password: 'secret',
      enable_starttls_auto: true,
      authentication: :plain
    }

    assert_equal expected_settings, captured[:settings]
    assert_equal true, captured[:loaded]
  end
end

# frozen_string_literal: true

require 'test_helper'
require_relative '../app/daemon'

class HarnessTest < Minitest::Test
  def setup
    @previous = MediaLibrarian.instance_variable_get(:@application)
  end

  def teardown
    MediaLibrarian.application = @previous
  end

  def test_home_is_isolated_from_the_real_one
    assert_equal TEST_HOME, Dir.home
    assert Daemon::SOCKET_PATH.start_with?(TEST_HOME), 'daemon socket must live under the test HOME'
  end

  def test_two_real_applications_share_one_loader
    first = MediaLibrarian::Application.new
    second = MediaLibrarian::Application.new

    assert_kind_of Zeitwerk::Loader, first.loader
    assert_same first.loader, second.loader
    refute_same first.container, second.container, 'each application keeps its own container'
    assert first.config_dir.start_with?(TEST_HOME)
  end

  def test_lazy_application_can_be_rebuilt_after_reset
    MediaLibrarian.application = nil
    first = MediaLibrarian.application
    MediaLibrarian.application = nil
    second = MediaLibrarian.application

    refute_same first, second
    assert_same first.loader, second.loader
  end
end

# frozen_string_literal: true

require 'test_helper'
require_relative '../app/client'

class ClientConnectionErrorsTest < Minitest::Test
  def setup
    super
    reset_librarian_state!
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Client.configure(app: @environment.application)
  end

  def teardown
    MediaLibrarian.application = nil
    remove_app_reference(Client)
    @environment&.cleanup
    reset_librarian_state!
    super
  end

  def test_connection_errors_are_translated_into_service_unavailable
    client = Client.new

    {
      Errno::ECONNREFUSED => 'Failed to connect to daemon',
      Net::ReadTimeout => 'Timed out waiting for daemon response',
      Net::OpenTimeout => 'Timed out waiting for daemon response'
    }.each do |error_class, expected_message|
      Net::HTTP.stub(:start, ->(*) { raise error_class }) do
        response = client.status
        assert_equal 503, response['status_code']
        assert_equal expected_message, response['error']
      end
    end
  end

end

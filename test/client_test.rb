# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../app/client'

class ClientTest < Minitest::Test
  def setup
    super
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Client.configure(app: @environment.application)
  end

  def teardown
    @environment.cleanup if @environment
    MediaLibrarian.application = nil
    super
  end

  def test_enqueue_includes_control_token_in_payload
    configure_control_token('secret-token')

    request = capture_request { Client.new.enqueue(['status']) }

    refute_nil request
    payload = JSON.parse(request.body)
    assert_equal 'secret-token', payload['token']
    assert_equal 'secret-token', request['X-Control-Token']
  end

  def test_status_appends_control_token_to_query
    configure_control_token('query-token')

    request = capture_request { Client.new.status }

    refute_nil request
    assert_equal 'query-token', request['X-Control-Token']
    query_parts = request.uri.query.to_s.split('&')
    assert_includes query_parts, 'token=query-token'
  end

  def test_requests_include_cli_marker_header
    request = capture_request { Client.new.status }

    refute_nil request
    assert_equal 'librarian-cli', request['X-Requested-By']
  end

  private

  def configure_control_token(token)
    options = @environment.application.api_option.merge('control_token' => token)
    @environment.application.api_option = options
    @environment.container.reload_api_option!
  end

  def capture_request
    captured = nil
    response = Struct.new(:code, :body).new('200', '{}')

    Net::HTTP.stub(:start, lambda do |*_args, **_kwargs, &block|
      http = Object.new
      http.define_singleton_method(:read_timeout=) { |_value| }
      http.define_singleton_method(:request) do |req|
        captured = req
        response
      end
      block.call(http)
    end) do
      yield
    end

    captured
  end
end

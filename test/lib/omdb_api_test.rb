# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'date'
require_relative '../../lib/omdb_api'

class Env
  def self.debug?(*) = false
end unless defined?(Env)

class OmdbApiTest < Minitest::Test
  FIXTURE_PATH = File.expand_path('../fixtures/omdb_malformed.json', __dir__)

  def test_title_handles_malformed_json
    client = fake_client
    api = OmdbApi.new(http_client: client, api_key: 'sample-key')

    result = api.title('tt1234567')

    refute_nil result
    assert_equal 'Sample Title', result[:title]
    assert_equal ['Action'], result[:genres]
    assert_equal({ 'imdb' => 'tt1234567' }, result[:ids])
  end

  private

  def fake_client
    Class.new do
      attr_reader :received_path, :received_options

      define_method(:get) do |path, **opts|
        @received_path = path
        @received_options = opts
        Struct.new(:code, :body).new(200, File.read(OmdbApiTest::FIXTURE_PATH))
      end
    end.new
  end
end

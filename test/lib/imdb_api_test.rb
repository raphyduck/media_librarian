# frozen_string_literal: true

require_relative '../test_helper'

require 'json'
require 'date'
require_relative '../../lib/imdb_api'

class ImdbApiTest < Minitest::Test
  FIXTURE_PATH = File.expand_path('../fixtures/imdb_calendar.json', __dir__)

  def test_calendar_returns_entries_from_fixture_response
    date = Date.new(2024, 12, 5)
    client = fake_client
    api = ImdbApi.new(http_client: client, api_key: 'sample-key')

    entries = api.calendar(date_range: date..date)

    refute_empty entries
    assert_equal 'Sample Calendar Movie', entries.first['title']
    assert_equal '2024-12-05', entries.first['releaseDate']
    assert_equal(
      "#{ImdbApi::DEFAULT_BASE_URL}/imdb-api/v1/calendar",
      client.received_path
    )
  end

  private

  def fake_client
    Class.new do
      attr_reader :received_path, :received_options

      define_method(:get) do |path, **opts|
        @received_path = path
        @received_options = opts
        Struct.new(:code, :body).new(200, File.read(ImdbApiTest::FIXTURE_PATH))
      end
    end.new
  end
end

# frozen_string_literal: true

require_relative '../test_helper'

require 'json'
require 'date'
require_relative '../../lib/imdb_api'

class ImdbApiTest < Minitest::Test
  FIXTURE_PATH = File.expand_path('../fixtures/imdb_calendar.json', __dir__)

  def test_calendar_returns_entries_from_fixture_response
    date = Date.new(2024, 12, 5)
    api = ImdbApi.new(http_client: fake_client, api_key: 'sample-key')

    entries = api.calendar(date_range: date..date)

    refute_empty entries
    assert_equal 'Sample Calendar Movie', entries.first['title']
    assert_equal '2024-12-05', entries.first['releaseDate']
  end

  private

  def fake_client
    body = File.read(FIXTURE_PATH)

    Class.new do
      define_method(:get) do |_path, **_opts|
        Struct.new(:code, :body).new(200, body)
      end
    end.new
  end
end

# frozen_string_literal: true

require 'minitest/autorun'
require 'date'
require_relative '../../lib/db/migrations/support/calendar_entry_enricher'

class CalendarEntryEnricherTest < Minitest::Test
  def setup
    CalendarEntryEnricher.instance_variable_set(:@omdb_api, nil)
  end

  def test_fails_fast_without_api_configuration
    CalendarEntryEnricher.stub(:omdb_api, nil) do
      assert_raises(StandardError) { CalendarEntryEnricher.enrich([{}]) }
    end
  end

  def test_enriches_show_entries_via_title_search
    api = FakeApi.new
    entry = {
      title: 'Sample Show',
      media_type: 'show',
      release_date: Date.new(2024, 1, 1),
      ids: {},
      genres: [],
      languages: [],
      countries: [],
      poster_url: nil,
      backdrop_url: nil,
      rating: nil,
      imdb_votes: nil
    }

    enriched = CalendarEntryEnricher.stub(:omdb_api, api) { CalendarEntryEnricher.enrich([entry]).first }

    assert_equal 'series', api.calls.first[:type]
    assert_equal 'tt1234567', enriched[:ids]['imdb']
    assert_in_delta 8.1, enriched[:rating]
    assert_equal ['Drama'], enriched[:genres]
    assert_equal Date.new(2024, 1, 1), enriched[:release_date]
  end

  class FakeApi
    attr_reader :calls

    def initialize
      @calls = []
    end

    def title(*)
      nil
    end

    def find_by_title(title:, year:, type:)
      @calls << { title: title, year: year, type: type }
      {
        title: title,
        ids: { 'imdb' => 'tt1234567' },
        rating: 8.1,
        imdb_votes: 1234,
        genres: ['Drama'],
        languages: ['en'],
        countries: ['US'],
        release_date: Date.new(year || 2024, 1, 1),
        poster_url: 'https://example.test/poster.jpg'
      }
    end
  end
end

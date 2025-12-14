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

  def test_overwrites_metadata_but_preserves_imdb_id
    api = OverwritingFakeApi.new
    entry = {
      title: 'Different Poster',
      media_type: 'movie',
      imdb_id: 'imdb777',
      ids: { imdb: 'imdb777' },
      synopsis: 'Old synopsis',
      poster_url: 'https://example.test/old.jpg',
      rating: 5.0,
      release_date: Date.new(2020, 1, 1),
      genres: ['Action']
    }

    enriched = CalendarEntryEnricher.stub(:omdb_api, api) { CalendarEntryEnricher.enrich([entry]).first }

    assert_equal 'imdb777', enriched[:imdb_id]
    assert_equal 'https://example.test/new.jpg', enriched[:poster_url]
    assert_in_delta 9.2, enriched[:rating]
    assert_equal 'Updated synopsis', enriched[:synopsis]
    assert_equal Date.new(2024, 2, 2), enriched[:release_date]
    assert_equal ['Drama', 'Mystery'], enriched[:genres]
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

  class OverwritingFakeApi
    def title(*)
      {
        title: 'Different Poster',
        ids: { 'imdb' => 'tt9999999' },
        synopsis: 'Updated synopsis',
        rating: 9.2,
        imdb_votes: 5555,
        poster_url: 'https://example.test/new.jpg',
        backdrop_url: 'https://example.test/new_backdrop.jpg',
        release_date: Date.new(2024, 2, 2),
        genres: ['Drama', 'Mystery'],
        languages: ['en'],
        countries: ['US']
      }
    end

    def find_by_title(*)
      nil
    end
  end
end

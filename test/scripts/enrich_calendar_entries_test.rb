# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require 'date'
require_relative '../../scripts/enrich_calendar_entries'

class EnrichCalendarEntriesTest < Minitest::Test
  def setup
    @entries = [
      {
        id: 1,
        title: 'Verbose Film',
        synopsis: '',
        poster_url: '',
        backdrop_url: '',
        release_date: nil,
        genres: '[]',
        languages: '[]',
        countries: '[]',
        rating: nil,
        imdb_votes: nil,
        ids: '{}',
        media_type: 'movie',
        external_id: nil,
        source: nil
      }
    ]
    @dataset = FakeDataset.new(@entries)
    @db = FakeDB.new(@dataset)
  end

  def test_logs_progress_and_updates
    enriched_entry = @entries.first.merge(
      poster_url: 'poster.jpg',
      synopsis: 'A story.',
      release_date: Date.new(2024, 2, 2),
      genres: ['Drama'],
      languages: ['en'],
      countries: ['US'],
      rating: 8.0,
      imdb_votes: 123,
      ids: { imdb: 'tt123' }
    )

    out = StringIO.new
    CalendarEntryEnricher.stub(:enrich, [enriched_entry]) do
      CalendarEntriesEnrichment.run(@db, out: out)
    end

    output = out.string
    assert_includes output, 'Scanning 1 calendar entries'
    assert_includes output, 'Found 1 entries needing enrichment'
    assert_includes output, 'Enriching 1 entries via OMDb'
    assert_includes output, 'Updated entry 1 (Verbose Film) with '
    assert_equal 'poster.jpg', @dataset.updates[1][:poster_url]
  end

  def test_overwrites_mismatched_metadata_but_keeps_imdb_id
    @entries.first.merge!(
      synopsis: 'Outdated synopsis',
      poster_url: 'old.jpg',
      rating: 4.5,
      imdb_id: 'imdb-fixed',
      countries: '[]'
    )

    enriched_entry = @entries.first.merge(
      synopsis: 'Fresh synopsis',
      poster_url: 'new.jpg',
      rating: 8.7,
      imdb_id: 'imdb-new',
      countries: ['US']
    )

    out = StringIO.new
    CalendarEntryEnricher.stub(:enrich, [enriched_entry]) do
      CalendarEntriesEnrichment.run(@db, out: out)
    end

    updates = @dataset.updates[1]
    assert_equal 'new.jpg', updates[:poster_url]
    assert_equal 'Fresh synopsis', updates[:synopsis]
    assert_in_delta 8.7, updates[:rating]
    refute_includes updates.keys, :imdb_id
  end

  class FakeDB
    attr_reader :database

    def initialize(dataset)
      @database = FakeDatabase.new(dataset)
    end
  end

  class FakeDatabase
    def initialize(dataset)
      @dataset = dataset
    end

    def [](key)
      key == :calendar_entries ? @dataset : nil
    end
  end

  class FakeDataset
    attr_reader :updates

    def initialize(entries)
      @entries = entries
      @updates = {}
    end

    def map(&block)
      @entries.map(&block)
    end

    def where(id:)
      FakeWhere.new(self, id)
    end

    class FakeWhere
      def initialize(dataset, id)
        @dataset = dataset
        @id = id
      end

      def update(values)
        @dataset.updates[@id] = values
      end
    end
  end
end

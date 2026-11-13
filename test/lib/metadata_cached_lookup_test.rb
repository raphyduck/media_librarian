# frozen_string_literal: true

require_relative '../test_helper'

class MetadataCachedLookupTest < Minitest::Test
  class FakeMetadataDb
    attr_reader :deleted

    def initialize(rows)
      @rows = rows.dup
      @deleted = []
    end

    def get_rows(table, conditions)
      return [] unless table.to_s == 'metadata_search'

      @rows.select do |r|
        conditions.all? { |k, v| r[k].to_s == v.to_s }
      end
    end

    def delete_rows(table, conditions)
      return unless table.to_s == 'metadata_search'

      removed = @rows.select { |r| conditions.all? { |k, v| r[k].to_s == v.to_s } }
      @rows -= removed
      @deleted.concat(removed)
    end
  end

  def setup
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Cache.instance_variable_set(:@cache_metadata, Vash.new)
    @keys = { 'name' => 'name', 'titles' => 'alt_titles', 'url' => 'url', 'year' => 'year' }
    @ids = { 'imdb' => 'tt33852162' }
  end

  def teardown
    remove_app_reference(Cache)
    remove_app_reference(Metadata)
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def build_movie(name:, year:, imdb_id:)
    Movie.new({
                'title' => name,
                'original_title' => name,
                'year' => year,
                'ids' => { 'imdb' => imdb_id },
                'imdb_id' => imdb_id,
                'release_date' => "#{year}-01-01"
              }, app: @environment.application)
  end

  def cache_row_for(title, movie)
    packed = Cache.object_pack([title, movie])
    { type: 2, keywords: "#{title}|tt33852162|",
      created_at: Time.now.utc.iso8601,
      result: JSON.generate(packed) }
  end

  def test_object_unpack_preserves_imdb_id
    movie = build_movie(name: 'Vie privée', year: 2025, imdb_id: 'tt33852162')
    packed = Cache.object_pack([movie.name, movie])
    json = JSON.generate(packed)
    unpacked = Cache.object_unpack(json)

    assert_equal 'Vie privée', unpacked[0]
    assert_kind_of Movie, unpacked[1]
    assert_equal 'tt33852162', unpacked[1].ids['imdb']
  end

  def test_inconsistent_cached_lookup_with_different_imdb_id_is_discarded
    wrong_movie = build_movie(name: 'Vie privée', year: 1930, imdb_id: 'tt99999999')
    db = FakeMetadataDb.new([cache_row_for('Vie privée (2025)', wrong_movie)])
    @environment.application.db = db

    fetched = false
    fetcher = lambda do |ids|
      fetched = true
      ['Vie privée (2025)', build_movie(name: 'Vie privée', year: 2025, imdb_id: ids['imdb'])]
    end

    Cache.stub(:cache_add, nil) do
      title, item = Metadata.media_lookup('movies', 'Vie privée (2025)', 'movie_lookup',
                                          @keys, fetcher, [], 1, '', @ids)
      assert fetched, 'authoritative fetch must run when cached imdb_id differs'
      assert_equal 'tt33852162', item.ids['imdb']
      assert_equal 'Vie privée (2025)', title
    end
  end

  def test_consistent_cached_lookup_with_same_imdb_id_is_served
    right_movie = build_movie(name: 'Vie privée', year: 2025, imdb_id: 'tt33852162')
    db = FakeMetadataDb.new([cache_row_for('Vie privée (2025)', right_movie)])
    @environment.application.db = db

    fetched = false
    fetcher = lambda do |_ids|
      fetched = true
      ['should not run', build_movie(name: 'Vie privée', year: 2025, imdb_id: 'tt33852162')]
    end

    title, item = Metadata.media_lookup('movies', 'Vie privée (2025)', 'movie_lookup',
                                        @keys, fetcher, [], 1, '', @ids)
    refute fetched, 'authoritative fetch must NOT run when cached imdb_id matches'
    assert_equal 'tt33852162', item.ids['imdb']
    assert_equal 'Vie privée', title
  end

  def test_cached_lookup_consistent_rejects_non_matching_title
    wrong_movie = build_movie(name: 'La Vie privée des romains', year: 1900, imdb_id: '')

    consistent = Metadata.cached_lookup_consistent?('movies', wrong_movie, 'Vie privée (2025)', {}, @keys)

    refute consistent, 'a cache entry whose title does not match must be rejected'
  end

  def test_cached_lookup_consistent_accepts_matching_title
    movie = build_movie(name: 'Vie privée', year: 2025, imdb_id: '')

    consistent = Metadata.cached_lookup_consistent?('movies', movie, 'Vie privée (2025)', {}, @keys)

    assert consistent, 'a cache entry whose title matches must be accepted'
  end
end

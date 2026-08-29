# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/languages'
require_relative '../../lib/string_utils'
require_relative '../../lib/metadata'
require_relative '../../app/tv_series'

{
  SPACE_SUBSTITUTE: '\\. _\\-',
  VALID_VIDEO_EXT: '(.*)\\.(mkv)$',
  BASIC_EP_MATCH: '((s|S)\\d{1,3}[exEX]\\d{1,4})'
}.each do |const, value|
  Object.const_set(const, value) unless Object.const_defined?(const)
end

class TvSeriesImdbBackfillTest < Minitest::Test
  def setup
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    TvSeries.configure(app: @environment.application)
    ensure_tvmaze_stub
  end

  def teardown
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def ensure_tvmaze_stub
    Object.const_set(:TVMaze, Module.new) unless defined?(TVMaze)
    TVMaze.const_set(:Show, Class.new) unless defined?(TVMaze::Show)
    TVMaze::Show.define_singleton_method(:lookup) { |_params| nil } unless TVMaze::Show.respond_to?(:lookup)
  end

  def build_show(ids)
    TvSeries.new({ 'ids' => ids, 'name' => 'Example Show', 'premiered' => '2019-03-04' },
                 app: @environment.application)
  end

  # TVDB records routinely carry IMDB_ID as an empty string; a blank is truthy
  # in Ruby and used to shadow every fallback, landing the show in the library
  # with no id at all.
  def test_blank_ids_are_dropped_at_construction
    show = TvSeries.new({ 'seriesid' => '4242', 'IMDB_ID' => '', 'name' => 'Example Show',
                          'premiered' => '2019-03-04' }, app: @environment.application)

    assert_nil show.ids['imdb']
    assert_equal '4242', show.ids['thetvdb']
  end

  def test_backfills_the_imdb_id_from_tvmaze_via_the_tvdb_id
    show = build_show({ 'thetvdb' => '4242' })
    external = Struct.new(:ids).new({ 'imdb' => 'tt7654321', 'thetvdb' => 4242 })

    TVMaze::Show.stub(:lookup, lambda { |params|
      assert_equal({ 'thetvdb' => '4242' }, params)
      external
    }) do
      TvSeries.backfill_imdb_id(show)
    end

    assert_equal 'tt7654321', show.ids['imdb']
  end

  def test_backfill_leaves_the_id_absent_when_no_source_knows_of_it
    show = build_show({ 'thetvdb' => '4242' })

    TVMaze::Show.stub(:lookup, ->(_params) { Struct.new(:ids).new({ 'thetvdb' => 4242 }) }) do
      TvSeries.stub(:tmdb_imdb_id_from_tvdb, ->(_id) { '' }) do
        TvSeries.backfill_imdb_id(show)
      end
    end

    assert_nil show.ids['imdb']
  end

  def test_backfill_falls_back_to_tmdb_when_tvmaze_is_throttled
    show = build_show({ 'thetvdb' => '4242' })

    TVMaze::Show.stub(:lookup, ->(_params) { raise StandardError, '429' }) do
      TvSeries.stub(:tmdb_imdb_id_from_tvdb, lambda { |tvdb_id|
        assert_equal '4242', tvdb_id
        'tt7366338'
      }) do
        TvSeries.backfill_imdb_id(show)
      end
    end

    assert_equal 'tt7366338', show.ids['imdb']
  end

  def test_backfill_does_not_touch_a_show_that_already_has_an_id
    show = build_show({ 'thetvdb' => '4242', 'imdb' => 'tt1111111' })
    guard = ->(_params) { flunk 'TVMaze must not be queried when the id is already known' }

    TVMaze::Show.stub(:lookup, guard) do
      TvSeries.backfill_imdb_id(show)
    end

    assert_equal 'tt1111111', show.ids['imdb']
  end

  def test_backfill_survives_a_tvmaze_failure
    show = build_show({ 'thetvdb' => '4242' })

    TVMaze::Show.stub(:lookup, ->(_params) { raise StandardError, 'tvmaze down' }) do
      TvSeries.stub(:tmdb_imdb_id_from_tvdb, ->(_id) { '' }) do
        TvSeries.backfill_imdb_id(show)
      end
    end

    assert_nil show.ids['imdb']
  end
  class FakeTmdbTvSearch
    class << self
      attr_accessor :results, :params
    end

    def initialize(_resource = nil)
      self.class.params = {}
    end

    def query(value)
      self.class.params[:query] = value
      self
    end

    def filter(conditions)
      self.class.params.merge!(conditions)
      self
    end

    def fetch
      self.class.results
    end
  end

  def test_tmdb_search_builds_candidates_carrying_their_external_ids
    Object.const_set(:Tmdb, Module.new) unless defined?(::Tmdb)
    Tmdb.const_set(:Search, FakeTmdbTvSearch) unless defined?(Tmdb::Search)
    Tmdb.const_set(:TV, Class.new) unless defined?(Tmdb::TV)
    Tmdb::TV.define_singleton_method(:detail) { |*| nil } unless Tmdb::TV.respond_to?(:detail)

    FakeTmdbTvSearch.results = [
      { 'id' => 87108, 'name' => 'Chernobyl', 'first_air_date' => '2019-05-06', 'original_language' => 'en' }
    ]
    detail = { 'external_ids' => { 'imdb_id' => 'tt7366338', 'tvdb_id' => 360_893 } }

    Tmdb::TV.stub(:detail, ->(_id, **_opts) { detail }) do
      candidates = TvSeries.tmdb_search('Chernobyl', 2019)

      assert_equal 1, candidates.length
      assert_equal 'Chernobyl', candidates.first['name']
      assert_equal({ 'tmdb' => '87108', 'imdb' => 'tt7366338', 'thetvdb' => '360893' }, candidates.first['ids'])
      assert_equal 2019, FakeTmdbTvSearch.params[:first_air_date_year]
    end
  end
  # The storage layer parses cached JSON with symbolize_names: a TvSeries
  # rebuilt from the metadata cache arrives with symbol keys, and every
  # options['...'] read found nothing — shows came back from cache without
  # ids or name for as long as the cache has existed.
  def test_construction_accepts_symbol_keyed_options_from_the_cache
    show = TvSeries.new({ ids: { thetvdb: '248835', imdb: 'tt1843230', tvmaze: '111' },
                          name: 'Once Upon a Time (2011)', first_aired: '2011-10-23' },
                        app: @environment.application)

    assert_equal 'tt1843230', show.ids['imdb']
    assert_equal '248835', show.ids['thetvdb']
    assert_includes show.name, 'Once Upon a Time'
  end
end

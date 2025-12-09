# frozen_string_literal: true

require 'test_helper'
require 'time'
require 'timeout'
require_relative '../../app/movie'
require_relative '../../app/languages'
require_relative '../../lib/metadata'
require_relative '../../lib/trakt_agent'

class MovieTest < Minitest::Test
  unless Numeric.method_defined?(:years)
    class ::Numeric
      def years
        self * 365 * 24 * 60 * 60
      end
    end
  end

  def setup
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
  end

  def teardown
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def with_short_timeout(limit = 0.1)
    original_timeout = Timeout.method(:timeout)
    Timeout.stub(:timeout, ->(seconds, klass = nil, &block) { original_timeout.call([seconds, limit].min, klass, &block) }) do
      yield
    end
  end

  def without_cache
    singleton = Cache.singleton_class
    singleton.define_method(:cache_get) { |_type = nil, _keyword = nil, *_rest| nil } unless Cache.respond_to?(:cache_get)
    singleton.define_method(:cache_add) { |_type = nil, _keyword = nil, _result = nil, *_rest| nil } unless Cache.respond_to?(:cache_add)

    Cache.stub(:cache_get, nil) do
      Cache.stub(:cache_add, nil) do
        yield
      end
    end
  end

  def test_year_uses_release_date_without_trakt_lookup
    TraktAgent.define_singleton_method(:movie__releases) do |*_args|
      flunk 'TraktAgent.movie__releases should not be called when a release date is available'
    end

    movie = Movie.new(
      {
        'title' => String.new('Example (2024)'),
        'release_date' => '2024-05-01',
        'ids' => { 'imdb' => 'tt1234567' }
      },
      app: @environment.application
    )

    assert_equal 2024, movie.year
  ensure
    if defined?(TraktAgent) && TraktAgent.singleton_class.method_defined?(:movie__releases)
      TraktAgent.singleton_class.send(:remove_method, :movie__releases)
    end
  end

  def test_movie_get_returns_promptly_when_tmdb_lookup_times_out
    ensure_tmdb_stubs

    result = nil
    elapsed = measure_elapsed do
      with_short_timeout do
        without_cache do
          Tmdb::Movie.stub(:detail, ->(*) { sleep 1 }) do
            result = Movie.movie_get({ 'tmdb' => '1' }, app: @environment.application)
          end
        end
      end
    end

    assert_operator elapsed, :<, 0.5, "Tmdb lookup took too long (#{elapsed}s)"
    assert_equal ['', nil], result
    assert_includes error_contexts, 'Movie.movie_get tmdb lookup timed out'
  end

  def test_movie_get_returns_promptly_when_trakt_lookup_times_out
    ensure_tmdb_stubs

    result = nil
    elapsed = measure_elapsed do
      with_short_timeout do
        without_cache do
          Tmdb::Movie.stub(:detail, ->(*) { nil }) do
            TraktAgent.stub(:movie__summary, ->(*) { sleep 1 }) do
              result = Movie.movie_get({ 'trakt' => '1' }, app: @environment.application)
            end
          end
        end
      end
    end

    assert_operator elapsed, :<, 0.5, "Trakt lookup took too long (#{elapsed}s)"
    assert_equal ['', nil], result
    assert_includes error_contexts, 'Movie.movie_get trakt lookup timed out'
  end

  def test_movie_uses_force_title_when_title_is_missing
    movie = Movie.new(
      {
        'force_title' => 'Provided',
        'release_date' => '2021-02-02',
        'ids' => { 'imdb' => 'tt99999' }
      },
      app: @environment.application
    )

    assert_equal 'Provided (2021)', movie.name
    refute @environment.application.speaker.messages.any? { |msg| msg.include?('missing title') }
  end

  def test_movie_falls_back_to_ids_when_no_title_is_available
    movie = Movie.new(
      {
        'release_date' => '2020-01-01',
        'ids' => { 'imdb' => 'tt0000001' }
      },
      app: @environment.application
    )

    assert_equal 'tt0000001 (2020)', movie.name
    assert_includes @environment.application.speaker.messages,
                    'Movie.extract_value missing title, using fallback: tt0000001'
  end

  def test_movie_allows_missing_title_without_ids
    movie = Movie.new(
      {
        'release_date' => '2019-12-12'
      },
      app: @environment.application
    )

    assert_nil movie.name
    assert_includes @environment.application.speaker.messages,
                    'Movie.extract_value missing title, no fallback available: {"release_date"=>"2019-12-12"}'
  end

  private

  def ensure_tmdb_stubs
    unless defined?(Tmdb)
      Object.const_set(:Tmdb, Module.new)
    end
    unless defined?(Tmdb::Movie)
      Tmdb.const_set(:Movie, Class.new)
    end
    unless Tmdb::Movie.respond_to?(:detail)
      Tmdb::Movie.define_singleton_method(:detail) { nil }
    end

    unless defined?(TraktAgent)
      Object.const_set(:TraktAgent, Class.new)
    end
    unless TraktAgent.respond_to?(:movie__summary)
      TraktAgent.define_singleton_method(:movie__summary) { nil }
    end
  end

  def error_contexts
    @environment.application.speaker.messages.select { |msg| msg.is_a?(Array) && msg.first == :error }
                 .map { |(_, _, context)| context }
  end

  def measure_elapsed
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end
end

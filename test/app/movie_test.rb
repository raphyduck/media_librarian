# frozen_string_literal: true

require 'test_helper'
require 'time'
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
end

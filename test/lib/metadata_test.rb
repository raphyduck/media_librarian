# frozen_string_literal: true

require_relative '../test_helper'

require_relative '../../lib/metadata'

class MetadataTest < Minitest::Test
  def test_media_add_deep_duplicates_nested_attributes
    attrs = {
      metadata: {
        tags: ['action', { rating: 5 }]
      }
    }
    file_attrs = {}
    file = { name: 'file.mkv' }
    data = {}

    result = Metadata.media_add('Example', 'movies', 'Example Movie', ['id-1'], attrs, file_attrs, file, data)

    stored = result['id-1']
    refute_nil stored
    assert_equal ['action', { rating: 5 }], stored[:metadata][:tags]
    refute_same attrs[:metadata][:tags], stored[:metadata][:tags]
    refute_same attrs[:metadata][:tags].last, stored[:metadata][:tags].last
  end

  def test_media_lookup_retries_after_initial_failure
    unless Cache.respond_to?(:cache_get)
      Cache.singleton_class.class_eval do
        def cache_get(*) = nil
        def cache_add(*) = nil
      end
    end
    provider = Class.new do
      attr_reader :calls

      def initialize(responses)
        @responses = responses
        @calls = 0
      end

      def find(_title)
        @calls += 1
        @responses.shift
      end
    end.new([[], { 'name' => 'Found', 'ids' => { 'tmdb' => 1 }, 'year' => 2020 }])
    fetcher = ->(search_ids) { ['Found', search_ids.merge('name' => 'Found')] }

    second_item = nil
    Metadata.stub(:detect_real_title, ->(*) { 'Retry Movie' }) do
      Metadata.stub(:media_chose, ->(_title, items, *_rest) { [items.first['name'], items.first] }) do
        _, first_item = Metadata.media_lookup(
          'movies',
          'Retry Movie',
          'movie_lookup',
          { 'name' => 'name', 'url' => 'url', 'year' => 'year' },
          fetcher,
          [[provider, :find]],
          1
        )
        assert_nil first_item

        _, second_item = Metadata.media_lookup(
          'movies',
          'Retry Movie',
          'movie_lookup',
          { 'name' => 'name', 'url' => 'url', 'year' => 'year' },
          fetcher,
          [[provider, :find]],
          1
        )
      end
    end
    assert_equal 2, provider.calls
    refute_nil second_item
    assert_equal 'Found', second_item['name']
  end
end

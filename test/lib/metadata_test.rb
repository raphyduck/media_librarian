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
end

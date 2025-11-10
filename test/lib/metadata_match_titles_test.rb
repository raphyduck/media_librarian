# frozen_string_literal: true

require_relative '../test_helper'

require_relative '../../lib/utils'
require_relative '../../lib/metadata'

{
  SPACE_SUBSTITUTE: '\\. _\\-',
  VALID_VIDEO_EXT: '(.*)\\.(mkv)$',
  BASIC_EP_MATCH: '((s|S)\\d{1,3}[exEX]\\d{1,4})'
}.each do |const, value|
  Object.const_set(const, value) unless Object.const_defined?(const)
end

class MetadataMatchTitlesTest < Minitest::Test
  def test_ignores_optional_numeric_tokens_when_titles_match
    title = '20th Century Boys: Beginning of the End (2008)'
    target = '20th Century Boys 1 Beginning of the End (2008)'

    assert Metadata.match_titles(title, target, 2008, 2008, 'movies')
  end
end

# frozen_string_literal: true

require 'test_helper'
require_relative '../../lib/string_utils'
require_relative '../../lib/metadata'
require_relative '../../app/torrent_search'

class TorrentSearchTest < Minitest::Test
  def setup
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
  end

  def teardown
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def with_identity_real_title
    Metadata.stub(:detect_real_title, ->(name, *_) { name }) do
      yield
    end
  end

  def test_search_keywords_include_ascii_folded_variant_for_accented_titles
    with_identity_real_title do
      keywords = TorrentSearch.search_keywords_for(['Chasse Gardée'], 'movies')

      assert_equal [{ :s => 'Chasse Gardée' }, { :s => 'Chasse Gardee' }], keywords
    end
  end

  def test_search_keywords_fold_typographic_apostrophes
    with_identity_real_title do
      keywords = TorrentSearch.search_keywords_for(['L’Âme Idéale'], 'movies')

      assert_includes keywords, { :s => "L'Ame Ideale" }
    end
  end

  def test_search_keywords_have_no_duplicate_for_ascii_titles
    with_identity_real_title do
      keywords = TorrentSearch.search_keywords_for(['Hunting Ground'], 'movies')

      assert_equal [{ :s => 'Hunting Ground' }], keywords
    end
  end
end

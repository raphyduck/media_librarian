# frozen_string_literal: true

require_relative '../test_helper'

class TvSeriesTest < Minitest::Test
  def test_identify_tv_episodes_numbering_accepts_dot_between_season_and_episode
    numbers, ids = TvSeries.identify_tv_episodes_numbering('Animal Kingdom S04.E01 Janine - MTL666.mkv')

    assert_equal([{ s: 4, ep: 1, part: 0 }], numbers[4])
    assert_includes ids, 'S04E01'
  end
end

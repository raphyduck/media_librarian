# frozen_string_literal: true

require_relative '../test_helper'

require_relative '../../lib/quality'

class QualityTableTest < Minitest::Test
  def test_resolves_every_q_sort_category_to_its_constant
    (Q_SORT + %w[DIMENSIONS EXTRA_TAGS]).each do |name|
      assert_same Object.const_get(name), Quality.quality_table(name),
                  "quality_table('#{name}') should return the #{name} token array"
    end
  end

  def test_unknown_category_resolves_to_empty_array
    assert_equal [], Quality.quality_table('does_not_exist')
    assert_equal [], Quality.quality_table(nil)
  end

  def test_accepts_symbol_names
    assert_same RESOLUTIONS, Quality.quality_table(:RESOLUTIONS)
  end
end

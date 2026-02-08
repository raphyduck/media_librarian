# frozen_string_literal: true

require_relative '../test_helper'

require 'titleize'

SPACE_SUBSTITUTE = '\\.
 _\\-' unless defined?(SPACE_SUBSTITUTE)
FILENAME_NAMING_TEMPLATE = %w[
  full_name
  destination_folder
  movies_name
  series_name
  episode_season
  episode_numbering
  episode_name
  quality
  proper
  part
] unless defined?(FILENAME_NAMING_TEMPLATE)

Object.send(:remove_const, :TimeUtils) if defined?(TimeUtils) && !TimeUtils.is_a?(Class)

require_relative '../../lib/string_utils'
require_relative '../../lib/time_utils'
require_relative '../../lib/utils'

class UtilsTest < Minitest::Test
  def setup
    @thread = Thread.current
    @original_lock_time = @thread[:lock_time]
    @thread[:lock_time] = nil
  end

  def teardown
    @thread[:lock_time] = @original_lock_time
  end

  def test_lock_block_allows_reentrant_execution
    calls = []

    Utils.lock_block('sample'.dup) do
      calls << :outer
      Utils.lock_block('sample'.dup) { calls << :inner }
    end

    assert_equal %i[outer inner], calls
  end

  def test_lock_block_serializes_threads
    calls = Queue.new

    t1 = Thread.new do
      Utils.lock_block('parallel'.dup) do
        calls << :start_first
        sleep 0.05
        calls << :end_first
      end
    end

    sleep 0.01 until t1.status == 'sleep'

    t2 = Thread.new do
      Utils.lock_block('parallel'.dup) do
        calls << :start_second
        calls << :end_second
      end
    end

    [t1, t2].each(&:join)

    assert_equal %i[start_first end_first start_second end_second], Array.new(4) { calls.pop }
  end

  def test_lock_timer_register_merges_similar_prefixes
    Utils.lock_timer_register('processA', 1.0, @thread)
    Utils.lock_timer_register('processB', 2.0, @thread)

    assert_equal({ "process*" => 3.0 }, @thread[:lock_time])
  end

  def test_lock_time_get_formats_elapsed_time
    @thread[:lock_time] = {
      'outer' => 1.2,
      'inner' => 0.002
    }

    message = Utils.lock_time_get(@thread)

    assert_includes message, "1.2 seconds locked for 'outer'"
    assert_includes message, "0.002 second locked for 'inner'"
  ensure
    @thread[:lock_time] = nil
  end

  def test_lock_time_merge_accumulates_values
    source = { lock_time: { 'work' => 0.5 } }

    Utils.lock_time_merge(source, @thread)

    assert_includes @thread[:lock_time].keys, 'work'
    assert_includes Utils.lock_time_get(@thread), "0.5 second locked for 'work'"
  end

  def test_check_if_active_respects_daily_schedule
    active_hours = { 'start' => 8, 'end' => 17 }

    Time.stub(:now, Time.new(2024, 1, 1, 9, 0, 0)) do
      assert Utils.check_if_active(active_hours)
    end

    Time.stub(:now, Time.new(2024, 1, 1, 7, 0, 0)) do
      refute Utils.check_if_active(active_hours)
    end
  end

  def test_check_if_active_handles_overnight_windows
    hours = { 'start' => '22', 'end' => '6' }

    Time.stub(:now, Time.new(2024, 1, 1, 23, 0, 0)) do
      assert Utils.check_if_active(hours)
    end

    Time.stub(:now, Time.new(2024, 1, 1, 12, 0, 0)) do
      refute Utils.check_if_active(hours)
    end
  end

  def test_check_if_active_returns_true_for_invalid_input
    assert Utils.check_if_active(nil)
  end

  def test_match_release_year_allows_off_by_one
    assert Utils.match_release_year(2020, 2021)
    refute Utils.match_release_year(2020, 2025)
  end

  def test_recursive_typify_keys_symbolizes_by_default
    value = { 'foo' => { 'bar' => 1 }, 'list' => [{ 'baz' => 2 }] }

    result = Utils.recursive_typify_keys(value)

    assert_equal({ foo: { bar: 1 }, list: [{ baz: 2 }] }, result)
  end

  def test_recursive_typify_keys_can_preserve_strings
    value = { foo: { bar: 1 }, list: [{ baz: 2 }] }

    result = Utils.recursive_typify_keys(value, 0)

    assert_equal({ 'foo' => { 'bar' => 1 }, 'list' => [{ 'baz' => 2 }] }, result)
  end

  def test_parse_filename_template_substitutes_metadata
    metadata = {
      'full_name' => 'My Movie',
      'quality' => '1080P',
      'episode_name' => 'pilot'
    }

    template = '{{ full_name }} - {{ quality|downcase }} - {{ episode_name|titleize }}'

    parsed = Utils.parse_filename_template(template, metadata)

    assert_equal 'My Movie - 1080p - Pilot', parsed
  end
end

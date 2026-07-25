# frozen_string_literal: true

require 'test_helper'
require_relative '../../lib/simple_speaker'

class SimpleSpeakerTest < Minitest::Test
  FROZEN_MESSAGE = 'Adopted newer Trakt token found in database.'

  def setup
    @speaker = SimpleSpeaker::Speaker.new
    Thread.current[:log_msg] = nil
    Thread.current[:email_msg] = nil
    Thread.current[:send_email] = nil
  end

  def teardown
    Thread.current[:log_msg] = nil
    Thread.current[:email_msg] = nil
    Thread.current[:send_email] = nil
  end

  def test_speak_up_accepts_frozen_string_with_log_buffer
    Thread.current[:log_msg] = String.new(encoding: 'UTF-8')

    assert_equal FROZEN_MESSAGE, @speaker.speak_up(FROZEN_MESSAGE, 0)
    assert_includes Thread.current[:log_msg], FROZEN_MESSAGE
    assert FROZEN_MESSAGE.frozen?
  end

  def test_speak_up_accepts_frozen_string_in_email_buffer
    assert_equal FROZEN_MESSAGE, @speaker.speak_up(FROZEN_MESSAGE, 1)
    assert_includes Thread.current[:email_msg], FROZEN_MESSAGE
  end
end

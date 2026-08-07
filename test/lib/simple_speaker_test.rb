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
    Thread.current[:email_notable] = nil
  end

  def teardown
    Thread.current[:log_msg] = nil
    Thread.current[:email_msg] = nil
    Thread.current[:send_email] = nil
    Thread.current[:email_notable] = nil
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

  def test_speak_up_redacts_api_keys_in_urls
    url = "Will download 'X' (url = http://jackett:9117/dl/torr9/?jackett_apikey=abcdef123456&path=xyz&file=X)"
    Thread.current[:log_msg] = String.new(encoding: 'UTF-8')

    @speaker.speak_up(url, 1)

    refute_includes Thread.current[:email_msg], 'abcdef123456'
    refute_includes Thread.current[:log_msg], 'abcdef123456'
    assert_includes Thread.current[:email_msg], 'jackett_apikey=***'
    assert_includes Thread.current[:email_msg], 'path=xyz', 'non-sensitive params must stay readable'
  end

  def test_redact_secrets_masks_common_secret_shapes
    assert_equal 'passkey=***&x=1', SimpleSpeaker.redact_secrets('passkey=deadbeef&x=1')
    assert_equal "'password' => '***'", SimpleSpeaker.redact_secrets("'password' => 'hunter2'")
    assert_equal 'access_token: ***', SimpleSpeaker.redact_secrets('access_token: sk-123456')
    assert_equal 'rsskey=***', SimpleSpeaker.redact_secrets('rsskey=00ff00ff')
  end

  def test_redact_secrets_masks_url_encoded_links
    encoded = 'Link: http%3A%2F%2F127.0.0.1%3A9117%2Fdl%2Ftorr9%2F%3Fjackett_apikey%3Dsecret123%26path%3Dabc'
    redacted = SimpleSpeaker.redact_secrets(encoded)

    refute_includes redacted, 'secret123'
    assert_includes redacted, 'jackett_apikey%3D***'
    assert_includes redacted, '%26path%3Dabc', 'params after the encoded separator must stay readable'
  end

  def test_redact_secrets_leaves_plain_text_alone
    text = 'Torrent has been seeding for 3 hours, tracker torr9, size = 9057182720'
    assert_equal text, SimpleSpeaker.redact_secrets(text)
  end

  def test_routine_message_does_not_flag_notable
    @speaker.speak_up('routine info', 1)

    assert_equal 1, Thread.current[:send_email]
    assert_nil Thread.current[:email_notable]
  end

  def test_notable_message_flags_notable
    @speaker.speak_up('a download actually happened', 2)

    assert_equal 2, Thread.current[:send_email]
    assert_equal 1, Thread.current[:email_notable]
  end

  def test_tell_error_flags_notable
    @speaker.tell_error(StandardError.new('boom'), 'somewhere')

    assert Thread.current[:send_email].to_i.positive?
    assert_equal 1, Thread.current[:email_notable]
  end

  def test_silent_message_sets_neither_flag
    @speaker.speak_up('log only', 0)

    assert_nil Thread.current[:send_email]
    assert_nil Thread.current[:email_notable]
  end
end

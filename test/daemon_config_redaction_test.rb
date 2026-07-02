# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../app/daemon'

class DaemonConfigRedactionTest < Minitest::Test
  ORIGINAL = <<~YAML
    # top comment
    preferred_languages: fr en
    deluge:
      host: 10.0.0.5
      username: realuser
      password: DelugeSecret1
    email:
      host: smtp.example.com
      password: EmailSecret2
    auth:
      session_secret: abcdef0123456789
      password_hash: "$2a$12$realhash"
  YAML

  def test_redact_masks_secrets_but_preserves_structure_and_comments
    masked = Daemon.send(:redact_config_content, ORIGINAL)

    refute_includes masked, 'DelugeSecret1'
    refute_includes masked, 'EmailSecret2'
    refute_includes masked, 'abcdef0123456789'
    refute_includes masked, 'realhash'
    assert_includes masked, '# top comment'
    assert_includes masked, 'preferred_languages: fr en'
    assert_includes masked, 'host: 10.0.0.5'
  end

  def test_restore_keeps_edits_and_restores_untouched_secrets_by_path
    masked = Daemon.send(:redact_config_content, ORIGINAL)
    placeholder = Daemon.const_get(:CONFIG_REDACTION_PLACEHOLDER)
    edited = masked
             .sub('host: 10.0.0.5', 'host: 10.0.0.9')
             .sub("session_secret: #{placeholder}", 'session_secret: NEWSECRET')

    restored = Daemon.send(:restore_redacted_config, edited, ORIGINAL)

    assert_includes restored, 'host: 10.0.0.9'          # user edit kept
    assert_includes restored, 'password: DelugeSecret1' # untouched secret restored
    assert_includes restored, 'EmailSecret2'            # same-named key restored by path
    assert_includes restored, 'session_secret: NEWSECRET' # genuine change applied
    assert_includes restored, '$2a$12$realhash'
    refute_includes restored, placeholder
  end
end

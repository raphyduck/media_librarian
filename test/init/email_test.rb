# frozen_string_literal: true

require 'test_helper'
require 'mail'
require 'openssl'
require_relative '../../init/email'

class EmailInitTest < Minitest::Test
  def test_ssl_context_applies_custom_params
    verify_callback = ->(ok, store) { ok && store }

    smtp = Mail::SMTP.new(
      address: 'localhost',
      port: 25,
      ssl_context_params: { verify_mode: OpenSSL::SSL::VERIFY_NONE, verify_callback: verify_callback }
    )

    context = smtp.send(:ssl_context)

    assert_equal verify_callback, context.verify_callback
    assert_equal OpenSSL::SSL::VERIFY_NONE, context.verify_mode
  end
end

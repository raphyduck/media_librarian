# frozen_string_literal: true

require_relative '../test_helper'

require_relative '../../lib/media_librarian/session_crypto'

class SessionCryptoTest < Minitest::Test
  SECRET = 'a-very-secret-key'
  M = MediaLibrarian::SessionCrypto

  def test_encode_decode_round_trip
    data = { 'username' => 'alice', 'issued_at' => '2020-01-01T00:00:00Z' }
    token = M.encode(data, SECRET)
    assert_match(/\A[\w-]+\.[a-f0-9]+\z/, token)
    assert_equal data, M.decode(token, SECRET)
  end

  def test_decode_rejects_wrong_secret
    token = M.encode({ 'username' => 'alice' }, SECRET)
    assert_nil M.decode(token, 'different-secret')
  end

  def test_decode_rejects_tampered_payload
    token = M.encode({ 'username' => 'alice' }, SECRET)
    encoded, signature = token.split('.', 2)
    forged = { 'username' => 'admin' }
    tampered = "#{Base64.urlsafe_encode64(JSON.dump(forged), padding: false)}.#{signature}"
    assert_nil M.decode(tampered, SECRET)
    # sanity: the untouched token still decodes
    assert_equal({ 'username' => 'alice' }, M.decode("#{encoded}.#{signature}", SECRET))
  end

  def test_decode_handles_missing_secret_and_malformed_input
    assert_nil M.decode('anything', nil)
    assert_nil M.decode('no-dot-here', SECRET)
    assert_nil M.decode('', SECRET)
    assert_nil M.decode(nil, SECRET)
  end

  def test_secure_compare
    assert M.secure_compare('abc', 'abc')
    refute M.secure_compare('abc', 'abd')
    refute M.secure_compare('abc', 'abcd') # different length
    refute M.secure_compare(nil, 'abc')
    refute M.secure_compare('abc', nil)
  end
end

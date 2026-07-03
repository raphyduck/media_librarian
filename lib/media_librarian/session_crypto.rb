# frozen_string_literal: true

require 'base64'
require 'json'
require 'openssl'

module MediaLibrarian
  # Pure session-cookie cryptography: HMAC-signed, base64url-encoded payloads and
  # a constant-time comparison. Extracted from Daemon so these security-sensitive
  # primitives live in one place and can be unit-tested in isolation.
  module SessionCrypto
    module_function

    # Constant-time comparison, so a mismatch does not leak where it differs via
    # timing. Returns false unless both strings are present and equal length.
    def secure_compare(a, b)
      return false unless a && b

      a = a.to_s
      b = b.to_s
      return false unless a.bytesize == b.bytesize

      result = 0
      a.bytes.zip(b.bytes) { |x, y| result |= x ^ y }
      result.zero?
    end

    # Encode a data hash as "<base64url(json)>.<hmac-sha256>".
    def encode(data, secret)
      encoded = Base64.urlsafe_encode64(JSON.dump(data), padding: false)
      signature = OpenSSL::HMAC.hexdigest('SHA256', secret, encoded)
      "#{encoded}.#{signature}"
    end

    # Verify and decode a token produced by #encode. Returns the payload hash, or
    # nil when the secret is missing, the signature is invalid, or the payload is
    # malformed.
    def decode(value, secret)
      return nil unless secret

      encoded, signature = value.to_s.split('.', 2)
      return nil unless encoded && signature

      expected = OpenSSL::HMAC.hexdigest('SHA256', secret, encoded)
      return nil unless secure_compare(signature, expected)

      payload = JSON.parse(Base64.urlsafe_decode64(encoded))
      payload if payload.is_a?(Hash)
    rescue ArgumentError, JSON::ParserError
      nil
    end
  end
end

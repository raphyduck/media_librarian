# frozen_string_literal: true

# Session/token authentication for the daemon control server. Reopens Daemon's
# singleton class so these methods stay byte-for-byte identical to their prior
# inline definitions; extracted purely to shrink app/daemon.rb. Zeitwerk is told
# to ignore this file (see Application#setup_loader) because it reopens Daemon
# rather than defining a Daemon::SessionAuth constant.

class Daemon
  class << self
    def authentication_configured?
      auth_enabled? || !api_token.to_s.empty?
    end

    def auth_enabled?
      config = auth_config
      username = config['username']
      password_hash = config['password_hash']
      username && !username.empty? && password_hash && !password_hash.empty?
    end

    def api_token
      @api_token
    end

    def auth_config
      @auth_config ||= {}
    end

    def reload_api_option_config
      old_secret = defined?(@session_secret) ? @session_secret : nil
      app.container.reload_api_option!
      opts = app.api_option || {}
      @api_token = resolve_api_token(opts)
      @auth_config = normalize_auth_config(opts['auth'])
      configured_secret = @auth_config['session_secret']
      configured_secret = configured_secret.to_s unless configured_secret.nil?
      configured_secret = nil if configured_secret.to_s.empty?
      persisted_secret = nil

      if configured_secret.nil?
        path = File.join(app.config_dir, 'session_secret')
        persisted_secret = load_persisted_session_secret if File.file?(path) || old_secret.nil?
      end

      new_secret = configured_secret || persisted_secret || old_secret
      # Rotating the session secret invalidates existing sessions; avoid regeneration on reload unless it changed.
      @session_secret = new_secret if old_secret != new_secret
      true
    rescue StandardError => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding))
      false
    end

    def control_interface_local?(address)
      return true if address.to_s.empty?
      return true if %w[localhost 127.0.0.1 ::1].include?(address)

      IPAddr.new(address).loopback?
    rescue IPAddr::InvalidAddressError
      false
    end

    def require_authorization(req, res)
      unless authentication_configured?
        error_response(res, status: 503, message: 'auth_not_configured')
        return false
      end

      if authenticated_session?(req) || api_token_authorized?(req)
        true
      elsif api_token_provided_outside_header?(req)
        error_response(res, status: 400, message: 'token_header_required')
        false
      else
        error_response(res, status: 403, message: 'forbidden')
        false
      end
    end

    def authenticated_session?(req)
      !!session_from_request(req)
    end

    def session_from_request(req)
      session = session_cookie_payload(req)
      return unless session && session_valid?(session)

      session
    end

    def api_token_authorized?(req)
      token = api_token
      return false if token.to_s.empty?

      secure_compare(req['X-Control-Token'].to_s, token.to_s)
    end

    def api_token_provided_outside_header?(req)
      return false if api_token.to_s.empty?
      return false if req['X-Control-Token'] && !req['X-Control-Token'].empty?

      (req.respond_to?(:query) && token_present?(req.query['token'])) || token_in_request_body?(req)
    end

    def token_in_request_body?(req)
      return false unless req.body && !req.body.empty?

      parsed = JSON.parse(req.body)
      parsed.is_a?(Hash) && token_present?(parsed['token'])
    rescue JSON::ParserError
      false
    end

    def token_present?(value)
      !value.to_s.empty?
    end

    def handle_session_request(req, res)
      case req.request_method
      when 'POST'
        handle_session_create(req, res)
      when 'DELETE'
        handle_session_destroy(req, res)
      when 'GET'
        handle_session_show(req, res)
      else
        method_not_allowed(res, 'GET, POST, DELETE')
      end
    end

    def handle_session_create(req, res)
      unless auth_enabled?
        return error_response(res, status: 503, message: 'auth_not_configured')
      end

      begin
        payload = parse_payload(req)
      rescue JSON::ParserError => e
        return error_response(res, status: 422, message: e.message)
      end

      username = payload['username'].to_s
      password = payload['password'].to_s
      if username.empty? || password.empty?
        return error_response(res, status: 422, message: 'missing_credentials')
      end

      unless username == auth_config['username']
        return error_response(res, status: 401, message: 'invalid_credentials')
      end

      begin
        digest = BCrypt::Password.new(auth_config['password_hash'])
      rescue BCrypt::Errors::InvalidHash => e
        return error_response(res, status: 500, message: e.message)
      end

      unless digest == password
        return error_response(res, status: 401, message: 'invalid_credentials')
      end

      payload = build_session_payload(auth_config['username'])
      unless payload
        return error_response(res, status: 500, message: 'session_unavailable')
      end
      res.cookies << build_session_cookie(payload)
      json_response(res, status: 201, body: { 'username' => auth_config['username'] })
    end

    def handle_session_destroy(req, res)
      session = session_cookie_payload(req)
      revoke_session(session) if session
      res.cookies << expire_session_cookie
      json_response(res, status: 204)
    end

    def handle_session_show(req, res)
      unless auth_enabled?
        return error_response(res, status: 503, message: 'auth_not_configured')
      end

      session = session_from_request(req)
      unless session
        return error_response(res, status: 403, message: 'forbidden')
      end

      json_response(res, body: { 'username' => session['username'] })
    end

    def build_session_cookie(value)
      cookie = WEBrick::Cookie.new(SESSION_COOKIE_NAME, value.to_s)
      cookie.path = '/'
      cookie.secure = !!@session_cookie_secure
      cookie.instance_variable_set(:@httponly, true)
      # Block the cookie from being sent on cross-site requests (CSRF hardening)
      # for state-changing endpoints like /jobs.
      if cookie.respond_to?(:samesite=)
        cookie.samesite = :strict
      else
        cookie.instance_variable_set(:@samesite, :strict)
      end
      cookie
    end

    def expire_session_cookie
      cookie = build_session_cookie('')
      cookie.expires = Time.at(0)
      cookie
    end

    def normalize_auth_config(raw)
      return {} unless raw.is_a?(Hash)

      username = raw['username'] || raw[:username]
      password_hash = raw['password_hash'] || raw[:password_hash]
      session_secret = raw['session_secret'] || raw[:session_secret]

      result = {}
      result['username'] = username.to_s unless username.nil? || username.to_s.empty?
      result['password_hash'] = password_hash.to_s unless password_hash.nil? || password_hash.to_s.empty?
      result['session_secret'] = session_secret.to_s unless session_secret.nil? || session_secret.to_s.empty?
      result
    end

    def build_session_payload(username)
      secret = session_secret
      return unless secret

      now = Time.now.utc
      data = {
        'username' => username.to_s,
        'issued_at' => now.iso8601,
        'expires_at' => (now + SESSION_TTL).iso8601
      }
      encode_session_data(data, secret)
    end

    def session_cookie_payload(req)
      cookie = req.cookies.find { |c| c.name == SESSION_COOKIE_NAME }
      return unless cookie && !cookie.value.to_s.empty?

      decode_session_cookie(cookie.value)
    end

    def decode_session_cookie(value)
      MediaLibrarian::SessionCrypto.decode(value, session_secret)
    end

    def session_valid?(session)
      return false unless session.is_a?(Hash)

      username = session['username'].to_s
      issued_at = parse_session_time(session['issued_at'])
      expires_at = parse_session_time(session['expires_at'])
      now = Time.now.utc

      return false if username.empty? || issued_at.nil? || expires_at.nil?
      return false if expires_at <= now

      revoked_at = session_revocations[username]
      return false if revoked_at && issued_at <= revoked_at

      true
    end

    def revoke_session(session)
      return unless session.is_a?(Hash)

      username = session['username'].to_s
      return if username.empty?

      now = Time.now.utc
      previous = session_revocations[username]
      session_revocations[username] = previous && previous > now ? previous : now
    end

    def session_revocations
      @session_revocations ||= Concurrent::Hash.new
    end

    def parse_session_time(value)
      return if value.nil?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def encode_session_data(data, secret)
      MediaLibrarian::SessionCrypto.encode(data, secret)
    end

    def session_secret
      if defined?(@session_secret) && @session_secret
        ensure_session_secret_file(@session_secret)
        return @session_secret
      end

      secret = auth_config['session_secret']
      secret = secret.to_s unless secret.nil?
      secret = nil if secret.to_s.empty?
      secret ||= load_persisted_session_secret

      @session_secret = secret
      ensure_session_secret_file(secret)
      @session_secret
    end

    def load_persisted_session_secret
      path = File.join(app.config_dir, 'session_secret')

      if File.file?(path)
        secret = File.read(path).strip
        return secret unless secret.empty?
      end

      secret = SecureRandom.hex(32)
      File.write(path, secret)
      File.chmod(0o600, path)
      secret
    rescue SystemCallError => e
      app.speaker.tell_error(e, 'Unable to persist session secret')
      nil
    end

    def ensure_session_secret_file(secret)
      return unless secret

      path = File.join(app.config_dir, 'session_secret')
      return if File.file?(path) && !File.read(path).strip.empty?

      File.write(path, secret)
      File.chmod(0o600, path)
    rescue SystemCallError => e
      app.speaker.tell_error(e, 'Unable to persist session secret')
    end

    def secure_compare(a, b)
      MediaLibrarian::SessionCrypto.secure_compare(a, b)
    end

    def resolve_api_token(opts)
      return nil unless opts

      select_token(
        opts['api_token'],
        opts[:api_token],
        opts['control_token'],
        opts[:control_token],
        ENV['MEDIA_LIBRARIAN_API_TOKEN'],
        ENV['MEDIA_LIBRARIAN_CONTROL_TOKEN']
      )
    end

    def select_token(*candidates)
      candidates.each do |candidate|
        value = normalize_token(candidate)
        return value if value
      end
      nil
    end

    def normalize_token(candidate)
      case candidate
      when nil
        nil
      when String
        token = candidate.strip
        token.empty? ? nil : token
      else
        candidate
      end
    end
  end
end

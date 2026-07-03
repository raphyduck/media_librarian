# frozen_string_literal: true

# TLS/SSL setup for the daemon control server: the enable check, WEBrick SSL
# server options, CA and verify-mode resolution, credential loading, and
# self-signed certificate generation (with subject-alt-names). Reopens Daemon's
# singleton class so these methods stay byte-for-byte identical to their prior
# inline definitions; extracted purely to shrink app/daemon.rb. Zeitwerk is
# told to ignore this file (see Application#setup_loader) because it reopens
# Daemon rather than defining a Daemon::Tls constant.

class Daemon
  class << self
    def ssl_enabled?(opts)
      value = opts && (opts['ssl_enabled'] || opts[:ssl_enabled])
      truthy?(value)
    end

    def build_ssl_server_options(opts, address)
      certificate, private_key = load_tls_credentials(opts, address)
      ca_options = resolve_ssl_ca_options(opts)
      client_verify_mode = resolve_ssl_client_verify_mode(opts)
      options_mask = default_ssl_options_mask

      ssl_options = {
        SSLEnable: true,
        SSLPrivateKey: private_key,
        SSLCertificate: certificate,
        SSLVerifyClient: client_verify_mode,
        SSLStartImmediately: true
      }

      ssl_options[:SSLOptions] = options_mask unless options_mask.zero?
      ssl_options.merge!(ca_options) if ca_options
      ssl_options
    end

    def resolve_ssl_ca_options(opts)
      return unless opts

      ca_path = opts['ssl_ca_path'] || opts[:ssl_ca_path]
      return if ca_path.nil? || ca_path.to_s.empty?

      if File.directory?(ca_path)
        { SSLCACertificatePath: ca_path }
      elsif File.file?(ca_path)
        { SSLCACertificateFile: ca_path }
      else
        raise ArgumentError, "Invalid ssl_ca_path: #{ca_path}"
      end
    end

    def resolve_ssl_client_verify_mode(opts)
      return OpenSSL::SSL::VERIFY_NONE unless opts

      mode = opts['ssl_client_verify_mode'] || opts[:ssl_client_verify_mode]
      return OpenSSL::SSL::VERIFY_NONE if mode.nil? || mode.to_s.empty?

      resolve_ssl_verify_mode(mode)
    end

    def resolve_ssl_verify_mode(mode)
      return mode if mode.is_a?(Integer)

      case mode.to_s.downcase
      when '', 'none', 'off', 'false'
        OpenSSL::SSL::VERIFY_NONE
      when 'peer'
        OpenSSL::SSL::VERIFY_PEER
      when 'client_once'
        OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_CLIENT_ONCE
      when 'fail_if_no_peer_cert', 'force_peer', 'require'
        OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
      else
        OpenSSL::SSL::VERIFY_NONE
      end
    end

    def load_tls_credentials(opts, address)
      cert_path = opts['ssl_certificate_path'] || opts[:ssl_certificate_path]
      key_path = opts['ssl_private_key_path'] || opts[:ssl_private_key_path]

      if cert_path.to_s.empty? && key_path.to_s.empty?
        generate_self_signed_certificate(address)
      elsif cert_path.to_s.empty? || key_path.to_s.empty?
        raise ArgumentError, 'TLS requires both ssl_certificate_path and ssl_private_key_path'
      else
        certificate = OpenSSL::X509::Certificate.new(File.binread(cert_path))
        private_key = OpenSSL::PKey.read(File.binread(key_path))
        [certificate, private_key]
      end
    rescue Errno::ENOENT => e
      raise ArgumentError, "Unable to load TLS credentials: #{e.message}"
    rescue OpenSSL::PKey::PKeyError, OpenSSL::X509::CertificateError => e
      raise ArgumentError, "Invalid TLS credentials: #{e.message}"
    end

    def generate_self_signed_certificate(address)
      key = OpenSSL::PKey::RSA.new(2048)
      common_name = address.to_s.empty? ? 'MediaLibrarian' : address.to_s
      subject = OpenSSL::X509::Name.new([['CN', common_name]])
      certificate = OpenSSL::X509::Certificate.new
      certificate.version = 2
      certificate.serial = SecureRandom.random_number(1 << 64)
      certificate.subject = subject
      certificate.issuer = subject
      certificate.public_key = key.public_key
      certificate.not_before = Time.now - 60
      certificate.not_after = Time.now + 365 * 24 * 60 * 60

      extension_factory = OpenSSL::X509::ExtensionFactory.new
      extension_factory.subject_certificate = certificate
      extension_factory.issuer_certificate = certificate
      certificate.add_extension(extension_factory.create_extension('basicConstraints', 'CA:FALSE', true))
      certificate.add_extension(extension_factory.create_extension('keyUsage', 'keyEncipherment,dataEncipherment,digitalSignature', true))
      certificate.add_extension(extension_factory.create_extension('extendedKeyUsage', 'serverAuth', false))

      alt_names = build_subject_alt_names(address)
      certificate.add_extension(extension_factory.create_extension('subjectAltName', alt_names.join(','))) unless alt_names.empty?

      certificate.sign(key, OpenSSL::Digest::SHA256.new)

      app.speaker.speak_up('Génération d\'un certificat TLS auto-signé pour le serveur de contrôle.') if app&.speaker

      [certificate, key]
    end

    def build_subject_alt_names(address)
      names = ['DNS:localhost']
      names << 'IP:127.0.0.1'
      return names unless address && !address.to_s.empty?

      value = address.to_s
      if ip_address?(value)
        names << "IP:#{value}"
      else
        names << "DNS:#{value}"
      end
      names.uniq
    end

    def ip_address?(value)
      IPAddr.new(value)
      true
    rescue IPAddr::InvalidAddressError
      false
    end

    def default_ssl_options_mask
      mask = 0
      mask |= OpenSSL::SSL::OP_NO_SSLv2 if defined?(OpenSSL::SSL::OP_NO_SSLv2)
      mask |= OpenSSL::SSL::OP_NO_SSLv3 if defined?(OpenSSL::SSL::OP_NO_SSLv3)
      mask |= OpenSSL::SSL::OP_NO_COMPRESSION if defined?(OpenSSL::SSL::OP_NO_COMPRESSION)
      mask
    end
  end
end

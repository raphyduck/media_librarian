# Configure email alerts
require 'openssl'
require_relative '../boot/librarian'
require 'mail/network/delivery_methods/smtp'

app = MediaLibrarian::Boot.application
app.email_templates = File.expand_path('../app/mailer_templates', __dir__)
FileUtils.mkdir_p(app.email_templates) unless File.exist?(app.email_templates)
app.email = app.config['email']

if app.email
  host = app.email['host'].to_s.strip
  app.email = nil if host.empty? || host == 'host'
  return unless app.email

  module Mail
    class SMTP
      module VerifyCallback
        def ssl_context(*)
          super.tap do |context|
            skip_crl_error = OpenSSL::X509::V_ERR_UNABLE_TO_GET_CRL
            context.verify_callback = lambda do |preverify_ok, store|
              preverify_ok || store&.error == skip_crl_error
            end
          end
        end
      end

      prepend VerifyCallback
    end
  end

  smtp_open_timeout = (app.email['open_timeout'] || 30).to_i
  smtp_read_timeout = (app.email['read_timeout'] || 60).to_i

  Hanami::Mailer.configure do
    root app.email_templates
    delivery_method :smtp,
                    address:              app.email['host'],
                    port:                 app.email['port'],
                    domain:               app.email['domain'],
                    user_name:            app.email['username'],
                    password:             app.email['password'],
                    authentication:       app.email['auth_type'],
                    enable_starttls_auto: true,
                    openssl_verify_mode:  OpenSSL::SSL::VERIFY_PEER,
                    open_timeout:         smtp_open_timeout,
                    read_timeout:         smtp_read_timeout
  end.load!
end

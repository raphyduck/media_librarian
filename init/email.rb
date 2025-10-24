# Configure email alerts
require 'openssl'
require 'mail/network/delivery_methods/smtp'
require_relative '../boot/librarian'

module MediaLibrarian
  module SMTPVerifyCallback
    CRL_ERROR = OpenSSL::X509::V_ERR_UNABLE_TO_GET_CRL

    def ssl_context
      super.tap do |context|
        context.verify_callback ||= ->(ok, store) { ok || store&.error == CRL_ERROR }
      end
    end
  end
end

Mail::SMTP.prepend(MediaLibrarian::SMTPVerifyCallback)

app = MediaLibrarian::Boot.application
app.email_templates = File.expand_path('../app/mailer_templates', __dir__)
FileUtils.mkdir_p(app.email_templates) unless File.exist?(app.email_templates)
app.email = app.config['email']

if app.email
  Hanami::Mailer.configure do
    root app.email_templates
    delivery_method :smtp,
                    address:              app.email['host'],
                    port:                 app.email['port'],
                    domain:               app.email['domain'],
                    user_name:            app.email['username'],
                    password:             app.email['password'],
                    authentication:       app.email['auth_type'],
                    enable_starttls_auto: true
  end.load!
end

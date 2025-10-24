# Configure email alerts
require 'openssl'
require_relative '../boot/librarian'

app = MediaLibrarian::Boot.application
app.email_templates = File.expand_path('../app/mailer_templates', __dir__)
FileUtils.mkdir_p(app.email_templates) unless File.exist?(app.email_templates)
app.email = app.config['email']

if app.email
  Hanami::Mailer.configure do
    root app.email_templates
    skip_crl_error = OpenSSL::X509::V_ERR_UNABLE_TO_GET_CRL
    delivery_method :smtp,
                    address:              app.email['host'],
                    port:                 app.email['port'],
                    domain:               app.email['domain'],
                    user_name:            app.email['username'],
                    password:             app.email['password'],
                    authentication:       app.email['auth_type'],
                    enable_starttls_auto: true,
                    ssl_context_params:   {
                      verify_mode:    OpenSSL::SSL::VERIFY_PEER,
                      verify_callback: ->(ok, store) { ok || store&.error == skip_crl_error }
                    }
  end.load!
end

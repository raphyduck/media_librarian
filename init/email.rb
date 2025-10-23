# Configure email alerts
require_relative '../boot/librarian'

app = MediaLibrarian::Boot.application
app.email_templates = File.expand_path('../app/mailer_templates', __dir__)
FileUtils.mkdir_p(app.email_templates) unless File.exist?(app.email_templates)
app.email = app.config['email']

if app.email
  smtp_settings = {
    address: app.email['host'],
    port: app.email['port'],
    domain: app.email['domain'],
    user_name: app.email['username'],
    password: app.email['password'],
    enable_starttls_auto: true
  }

  auth_type = app.email['auth_type'].to_s.strip
  smtp_settings[:authentication] = auth_type.to_sym unless auth_type.empty?
  smtp_settings.delete_if { |_, value| value.nil? || (value.respond_to?(:empty?) && value.empty?) }

  Hanami::Mailer.configure do
    root app.email_templates
    delivery_method :smtp, smtp_settings
  end.load!
end

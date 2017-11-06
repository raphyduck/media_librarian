#Configure email alerts
$email_templates = File.dirname(__FILE__) + '/../app/mailer_templates'
Utils.file_mkdir($email_templates) unless File.exist?($email_templates)
$email = $config['email']
if $email
  Hanami::Mailer.configure do
    root $email_templates
    delivery_method :smtp,
                    address:              $email['host'],
                    port:                 $email['port'],
                    domain:               $email['domain'],
                    user_name:            $email['username'],
                    password:             $email['password'],
                    authentication:       $email['auth_type'],
                    enable_starttls_auto: true
  end.load!
end
$email_msg = ''
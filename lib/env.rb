class Env

  def self.debug?
    $env_flags[:debug].to_i > 0 || Thread.current[:debug].to_i > 0
  end

  def self.email_notif?
    $env_flags[:no_email_notif].to_i == 0 && Thread.current[:no_email_notif].to_i == 0
  end

  def self.pretend?
    $env_flags[:pretend].to_i > 0 || Thread.current[:pretend].to_i > 0
  end
end
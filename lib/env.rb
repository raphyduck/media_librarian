class Env

  def self.debug?(thread = Thread.current)
    $env_flags[:debug].to_i > 0 || thread[:debug].to_i > 0
  end

  def self.email_notif?(thread = Thread.current)
    $env_flags[:no_email_notif].to_i == 0 && thread[:no_email_notif].to_i == 0
  end

  def self.pretend?(thread = Thread.current)
    $env_flags[:pretend].to_i > 0 || thread[:pretend].to_i > 0
  end
end
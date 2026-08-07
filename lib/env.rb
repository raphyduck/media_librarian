class Env

  def self.debug?(thread = Thread.current)
    MediaLibrarian.app.env_flags[:debug].to_i > 0 || thread[:debug].to_i > 0
  end

  def self.email_notif?(thread = Thread.current)
    MediaLibrarian.app.env_flags[:no_email_notif].to_i == 0 && thread[:no_email_notif].to_i == 0
  end

  # 0 (default): any message flagged for email triggers a notification.
  # 1: only errors and notable events (speak_up in_mail >= 2) trigger one —
  # routine chatter from scheduled jobs stays out of the mailbox.
  def self.email_notif_level(thread = Thread.current)
    [MediaLibrarian.app.env_flags[:email_notif_level].to_i, thread[:email_notif_level].to_i].max
  end

  def self.pretend?(thread = Thread.current)
    MediaLibrarian.app.env_flags[:pretend].to_i > 0 || thread[:pretend].to_i > 0
  end
end
class Report
  include Hanami::Mailer
  from :from
  to :to
  cc :cc
  bcc :bcc
  subject :email_subject

  def action
    email_subject
  end

  def body
    current_msg = Thread.current[:email_msg]
    if defined?(body_s)
      body_s.nil? ? current_msg : body_s
    else
      current_msg
    end
  end

  def self.push_email(email_subject, ebody, trials = 10)
    return if trials <= 0
    deliver(
      object_s: formatted_subject(email_subject),
      body_s: StringUtils.fix_encoding(ebody.to_s)
    )
  rescue => e
    $speaker.tell_error(e, 'Report.push_email', 0)
    push_email(email_subject, ebody, trials - 1)
  end

  def self.sent_out(email_subject, t = Thread.current, content = '')
    email_content = content.to_s.empty? ? (t || Thread.current)[:email_msg].to_s : content.to_s
    if $email && !email_content.empty? && (t.nil? || t[:send_email].to_i > 0)
      Librarian.route_cmd(['Report', 'push_email', email_subject, email_content], 1, 'email', 1, 'priority')
      Librarian.reset_notifications(t) if t
      Thread.current[:parent] = nil
    end
  end

  private

  def email_notification(key)
    $email ? $email[key] : nil
  end

  def bcc
    email_notification('notification_bcc')
  end

  def cc
    email_notification('notification_cc')
  end

  def from
    email_notification('notification_from')
  end

  def to
    email_notification('notification_to')
  end

  # Renamed from "object" to "email_subject" to better reflect its usage.
  def email_subject
    object_s
  end

  def self.formatted_subject(subject)
    hostname = Socket.gethostname.to_s
    timestamp = Time.now.strftime("%a %d %b %Y")
    "[#{hostname}]#{subject} - #{timestamp}"
  end
end
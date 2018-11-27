class Report
  include Hanami::Mailer

  from :from
  to :to
  cc :cc
  bcc :bcc
  subject :object

  def action
    object
  end

  def body
    if defined? body_s
      body_s.nil? ? Thread.current[:email_msg] : body_s
    else
      Thread.current[:email_msg]
    end
  end

  def self.push_email(object, ebody, trials = 10)
    return if (trials -= 1) <= 0
    deliver(object_s: object.to_s + ' - ' + Time.now.strftime("%a %d %b %Y").to_s, body_s: ebody.to_s)
  rescue => e
    $speaker.tell_error(e, 'Report.push_email', 0)
    push_email(object, ebody, trials)
  end

  def self.sent_out(object, t = Thread.current, content = '')
    content = (t || Thread.current)[:email_msg].to_s if content.to_s == ''
    if $email && content.to_s != '' && (t.nil? || t[:send_email].to_i > 0)
      Librarian.route_cmd(['Report', 'push_email', object, content], 1, 'email', 1, (t || Thread.current)[:jid])
      Librarian.reset_notifications(t) if t
      Thread.current[:parent] = nil
    end
  end

  private

  def bcc
    $email ? $email['notification_bcc'] : nil
  end

  def cc
    $email ? $email['notification_cc'] : nil
  end

  def from
    $email ? $email['notification_from'] : nil
  end

  def object
    object_s
  end

  def to
    $email ? $email['notification_to'] : nil
  end
end
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

  def self.push_email(object, ebody)
    deliver(object_s: object.to_s + ' - ' + Time.now.strftime("%a %d %b %Y").to_s, body_s: ebody.to_s)
  rescue => e
    $speaker.tell_error(e, 'Report.push_email', 0)
    sent_out(object, ebody)
  end

  def self.sent_out(object, bs = Thread.current[:email_msg])
    Librarian.route_cmd(['Report', 'push_email', object, bs], 1, 'email') if $email && bs.to_s != '' && Thread.current[:send_email].to_i > 0
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
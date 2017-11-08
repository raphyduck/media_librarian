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

  def self.sent_out(object, bs = Thread.current[:email_msg])
    deliver(object_s: object + ' - ' + Time.now.strftime("%a %d %b %Y").to_s, body_s: bs) if $email && bs
    Thread.current[:email_msg] = ''
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
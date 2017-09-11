class Report
  include Hanami::Mailer

  from :from
  to   :to
  cc   :cc
  bcc  :bcc
  subject :object

  def action
    object
  end

  def body
    if defined? body_s
      body_s.nil? ? $email_msg : body_s
    else
      $email_msg
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
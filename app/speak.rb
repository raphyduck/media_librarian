class Speaker

  def self.ask_if_needed(question, no_prompt = 0, default = 'y')
    ask_if_needed = default
    if no_prompt.to_i == 0
      self.speak_up(question)
      ask_if_needed = STDIN.gets.strip
    end
    ask_if_needed
  end

  def self.speak_up(str)
    puts str
    $logger.info(str)
    $email_msg += str + NEW_LINE if $email_msg
  end

  def self.log(str)
    $logger.info(str)
  end

  def self.tell_error(e, src)
    puts "In #{src}"
    puts e
    $logger_error.error("ERROR #{Time.now.utc.to_s} #{src}")
    $logger_error.error(e)
    $email_msg += "ERROR #{Time.now.utc.to_s} #{src}" + NEW_LINE if $email_msg
    $email_msg += e.to_s + NEW_LINE if $email_msg
  end
end
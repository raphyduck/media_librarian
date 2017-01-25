class Speaker

  def self.speak_up(str)
    puts str
    $logger.info(str)
  end

  def self.log(str)
    $logger.info(str)
  end

  def self.tell_error(e, src)
    puts "In #{src}"
    puts e
    $logger_error.error("ERROR #{Time.now.utc.to_s} #{src}")
    $logger_error.error(e)
    $logger_error.error(e.backtrace.join("\n")) if e.backtrace
  end
end
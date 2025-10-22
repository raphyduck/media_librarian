# frozen_string_literal: true

require 'logger'

module SimpleSpeaker
  class Speaker
    def initialize(logger_path = nil, logger_error_path = nil)
      @logger = Logger.new(logger_path) unless logger_path.nil?
      @logger_error = Logger.new(logger_error_path) unless logger_error_path.nil?
      @daemons = []
      @user_input = nil
      @new_line = "\n"
    end

    def ask_if_needed(question, no_prompt = 0, default = 'y', thread = Thread.current)
      ask_if_needed = default
      if no_prompt.to_i == 0
        speak_up(question, 0, thread, 1)
        if Daemon.is_daemon?
          wtime = 0
          while @user_input.nil?
            sleep 1
            ask_if_needed = @user_input
            break if (wtime += 1) > USER_INPUT_TIMEOUT
          end
          @user_input = nil
        else
          ask_if_needed = STDIN.gets.strip
        end
      end
      ask_if_needed
    end

    def daemon_send(str)
      if Thread.current[:current_daemon]
        Thread.current[:current_daemon].send_data "#{str}\n"
      else
        puts str
      end
    end

    def email_msg_add(str, in_mail, thread)
      str = "[*] #{str}" if in_mail.to_i > 0
      thread[:email_msg] << str.to_s.force_encoding('UTF-8') + @new_line if thread[:email_msg]
      thread[:send_email] = in_mail.to_i if in_mail.to_i > 0 && thread[:send_email]
    end

    def speak_up(str, in_mail = 1, thread = Thread.current, immediate = 0)
      thread[:log_msg] << str.to_s + @new_line if thread[:log_msg]
      if immediate.to_i > 0 || thread[:log_msg].nil?
        str.to_s.each_line do |l|
          daemon_send(l)
          log("#{'[' + thread[:object].to_s + ']' if thread[:object].to_s != ''}#{l}")
        end
      end
      email_msg_add(str, in_mail, thread) if in_mail.to_i >= 0
      str
    end

    def log(str, error = 0)
      @logger.info(str) if @logger
      @logger_error.error(str) if @logger_error && error.to_i > 0
    end

    def tell_error(e, src, in_mail = 1, thread = Thread.current)
      @logger_error.error(e) if @logger_error
      speak_up("ERROR in '#{src}'" + @new_line, in_mail, thread)
      speak_up(e.to_s + @new_line, in_mail, thread)
      speak_up(e.backtrace[0..2].join(@new_line) + @new_line, in_mail, thread)
    end

    def user_input(input)
      @user_input = input
    end
  end
end

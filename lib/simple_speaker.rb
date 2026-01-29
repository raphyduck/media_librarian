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
        if defined?(Daemon) && Daemon.is_daemon?
          wtime = 0
          while @user_input.nil?
            sleep 1
            ask_if_needed = @user_input
            break if (wtime += 1) > USER_INPUT_TIMEOUT
          end
          @user_input = nil
        else
          input = STDIN.gets
          ask_if_needed = input.nil? ? nil : input.strip
        end
      end
      ask_if_needed = nil if ask_if_needed.respond_to?(:empty?) && ask_if_needed.empty?
      ask_if_needed.nil? ? default : ask_if_needed
    end

    def daemon_send(str, thread: Thread.current, stdout: $stdout, stderr: $stderr, daemon: nil)
      line = str.to_s
      payload = line.end_with?("\n") ? line : "#{line}\n"
      target = daemon || Thread.current[:current_daemon]
      if target
        target.send_data "#{line}\n"
      else
        (stdout || $stdout).puts(line)
      end
      output = if defined?(Daemon) && Daemon.respond_to?(:append_job_output)
                 Daemon.append_job_output(thread[:jid], payload, thread: thread)
               end
      buffer = thread[:captured_output]
      buffer&.<<(payload) if buffer && !buffer.equal?(output)
    end

    def email_msg_add(str, in_mail, thread)
      str = "[*] #{str}" if in_mail.to_i > 0
      buffer = thread[:email_msg]
      if buffer.nil?
        buffer = String.new
        thread[:email_msg] = buffer
      end

      buffer = buffer.dup if buffer.frozen?
      thread[:email_msg] = buffer
      buffer << str.to_s.force_encoding('UTF-8') + @new_line
      thread[:send_email] = in_mail.to_i if in_mail.to_i > 0
    end

    def speak_up(str, in_mail = 1, thread = Thread.current, immediate = 0)
      thread[:log_msg] << str.to_s + @new_line if thread[:log_msg] && immediate.to_i <= 0
      if immediate.to_i > 0 || thread[:log_msg].nil?
        str.to_s.each_line do |l|
          daemon_send(l, thread: thread)
          log("#{'[' + thread[:object].to_s + ']' if thread[:object].to_s != ''}#{l}")
        end
      end
      email_msg_add(str, in_mail, thread)
      str
    end

    def log(str, error = 0)
      @logger.info(str) if @logger
      @logger_error.error(str) if @logger_error && error.to_i > 0
    end

    def tell_error(e, src, in_mail = 1, thread = Thread.current)
      err = e.is_a?(Exception) ? e : StandardError.new(e.to_s)
      @logger_error.error(err) if @logger_error
      parts = []
      parts << "jid=#{thread[:jid]}" if thread[:jid].to_s != ''
      parts << "obj=#{thread[:object]}" if thread[:object].to_s != ''
      prefix = parts.empty? ? '' : "[#{parts.join(' ')}] "
      speak_up("#{prefix}ERROR in '#{src}'" + @new_line, in_mail, thread)
      speak_up(prefix + err.to_s + @new_line, in_mail, thread)
      speak_up(prefix + Array(err.backtrace)[0..2].join(@new_line) + @new_line, in_mail, thread)
    end

    def user_input(input)
      @user_input = input
    end
  end
end

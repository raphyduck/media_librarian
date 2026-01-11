# frozen_string_literal: true

require 'test_helper'
require_relative '../app/daemon'
require_relative '../librarian'

class DaemonChildNotificationsTest < Minitest::Test
  class FakeSpeaker
    attr_reader :daemon_lines, :speak_calls

    def initialize
      @daemon_lines = []
      @speak_calls = []
      @new_line = "\n"
    end

    def daemon_send(str, thread: Thread.current, **_args)
      line = str.to_s
      @daemon_lines << { line: line, thread: thread }
      buffer = thread[:captured_output]
      buffer&.<<(line.end_with?(@new_line) ? line : "#{line}#{@new_line}")
    end

    def speak_up(str, in_mail = 1, thread = Thread.current, immediate = 0)
      @speak_calls << { message: str, in_mail: in_mail, thread: thread, immediate: immediate }
      if thread[:log_msg] && immediate.to_i <= 0
        thread[:log_msg] << str.to_s + @new_line
      end
      if immediate.to_i > 0 || thread[:log_msg].nil?
        str.to_s.each_line { |line| daemon_send(line, thread: thread) }
      end
      return unless in_mail.to_i >= 0

      buffer = thread[:email_msg]
      return unless buffer

      prefix = in_mail.to_i > 0 ? "[*] " : ''
      buffer << prefix + str.to_s + @new_line
    end
  end

  def setup
    reset_librarian_state!
    @speaker = FakeSpeaker.new
    @environment = build_stubbed_environment(speaker: @speaker)
    @old_application = MediaLibrarian.application
    MediaLibrarian.application = @environment.application
    Librarian.configure(app: @environment.application)
    Daemon.configure(app: @environment.application)
  end

  def teardown
    @environment&.cleanup
    MediaLibrarian.application = @old_application
  end

  def test_merge_notifications_promotes_child_log_and_email
    children_count = Integer(ENV.fetch('CHILDREN', '2'))
    parent = Thread.new {}
    children = Array.new(children_count) { Thread.new {} }

    Librarian.reset_notifications(parent)
    parent[:log_msg] = nil
    parent[:captured_output] = String.new
    children.each do |child|
      child[:log_msg] = String.new
      child[:parent] = parent
      child[:email_msg] = String.new
    end

    children.each_with_index do |child, index|
      message = "Je suis l'enfant #{index + 1}"
      @speaker.speak_up(message, 0, child)
      Daemon.merge_notifications(child, parent)
    end

    puts parent[:captured_output]

    children.each_with_index do |child, index|
      message = "Je suis l'enfant #{index + 1}"
      assert @speaker.daemon_lines.any? { |entry| entry[:thread] == parent && entry[:line].include?(message) },
             'expected child log line to be sent to parent'
      assert_includes parent[:email_msg], message
    end
  ensure
    parent.join
    children.each(&:join)
  end
end

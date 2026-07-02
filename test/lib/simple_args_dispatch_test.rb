# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/simple_args_dispatch'

class SimpleArgsDispatchTest < Minitest::Test
  class RecordingSpeaker
    attr_reader :messages

    def initialize
      @messages = []
    end

    def speak_up(message, *)
      @messages << message
    end
  end

  # Target for launch() — captures the parsed keyword arguments.
  class DispatchTarget
    class << self
      attr_accessor :received

      def run(value: nil)
        self.received = value
      end
    end
  end

  def setup
    @speaker = RecordingSpeaker.new
    @agent = SimpleArgsDispatch::Agent.new(@speaker)
    DispatchTarget.received = nil
  end

  def test_show_available_lists_all_commands_not_just_two
    actions = { help: %w[X h], daemon: {}, library: {}, torrent: {}, music: {}, calendar: {} }
    @agent.show_available('librarian', actions, nil)

    usage = @speaker.messages.first
    %w[help daemon library torrent music calendar].each do |command|
      assert_includes usage, command, "usage line should advertise '#{command}'"
    end
  end

  def test_launch_parses_structured_argument_values
    @agent.launch('librarian', %w[SimpleArgsDispatchTest::DispatchTarget run], ['--value={a: 1, b: 2}'], nil, '')
    assert_equal({ 'a' => 1, 'b' => 2 }, DispatchTarget.received)
  end

  def test_launch_rejects_ruby_object_injection_in_argument_values
    payload = '--value=[!ruby/object:Gem::Requirement {}]'
    assert_raises(Psych::DisallowedClass) do
      @agent.launch('librarian', %w[SimpleArgsDispatchTest::DispatchTarget run], [payload], nil, '')
    end
    assert_nil DispatchTarget.received
  end
end

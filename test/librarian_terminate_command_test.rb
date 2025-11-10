# frozen_string_literal: true

require 'test_helper'

class LibrarianTerminateCommandTest < Minitest::Test
  class FakeThread
    def initialize(data = {})
      @data = data.transform_keys(&:to_sym)
    end

    def [](key)
      @data[key.to_sym]
    end

    def []=(key, value)
      @data[key.to_sym] = value
    end
  end

  def test_child_threads_defer_email_delivery_to_parent
    parent = build_thread(object: 'parent job', jid: 'parent-jid')
    child_one = build_thread(object: 'child-one', parent: parent, jid: 'child-jid-1')
    child_two = build_thread(object: 'child-two', parent: parent, jid: 'child-jid-2')

    sent_out_calls = []
    merged_children = []

    Env.stub(:email_notif?, ->(*) { true }) do
      Daemon.stub(:merge_notifications, ->(child, parent_thread) { merged_children << [child, parent_thread] }) do
        Report.stub(:sent_out, ->(subject, thread) { sent_out_calls << [subject, thread] }) do
          Librarian.terminate_command(child_one, 'child-value-1', child_one[:object])
          Librarian.terminate_command(child_two, 'child-value-2', child_two[:object])
          Librarian.terminate_command(parent, 'parent-value', parent[:object])
        end
      end
    end

    assert_equal [[child_one, parent], [child_two, parent]], merged_children
    assert_equal 1, sent_out_calls.size
    assert_equal parent, sent_out_calls.first.last
  end

  private

  def build_thread(**attrs)
    defaults = {
      base_thread: nil,
      is_active: 0,
      direct: 1,
      block: [],
      start_time: Time.now,
      object: 'job',
      jid: 'jid'
    }

    FakeThread.new(defaults.merge(attrs))
  end
end

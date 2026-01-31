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
    child_one = build_thread(object: 'child-one', parent: parent, jid: 'child-jid-1', child_job: 1)
    child_two = build_thread(object: 'child-two', parent: parent, jid: 'child-jid-2', child_job: 1)

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

  def test_inline_child_threads_skip_email_delivery
    inline_child = build_thread(object: 'inline-child', child_job: 1)

    Env.stub(:email_notif?, ->(*) { true }) do
      Daemon.stub(:merge_notifications, ->(*) { flunk('inline child should not merge notifications') }) do
        Report.stub(:sent_out, ->(*) { flunk('inline child should not send email') }) do
          Librarian.terminate_command(inline_child, 'inline-value', inline_child[:object])
        end
      end
    end
  end

  def test_scheduled_jobs_with_parent_but_not_child_job_send_email_directly
    # Scheduled jobs have parent set (scheduler thread) but child_job: 0
    # They should send email directly, not try to merge with parent
    scheduler_thread = build_thread(object: 'scheduler', jid: 'scheduler-jid')
    scheduled_job = build_thread(object: 'monitor_torrent_client', parent: scheduler_thread, jid: 'job-jid', child_job: 0)

    sent_out_calls = []
    merged_children = []

    Env.stub(:email_notif?, ->(*) { true }) do
      Daemon.stub(:merge_notifications, ->(child, parent_thread) { merged_children << [child, parent_thread] }) do
        Report.stub(:sent_out, ->(subject, thread) { sent_out_calls << [subject, thread] }) do
          Librarian.terminate_command(scheduled_job, 'job-value', scheduled_job[:object])
        end
      end
    end

    assert_empty merged_children, 'scheduled job should not merge notifications'
    assert_equal 1, sent_out_calls.size, 'scheduled job should send email directly'
    assert_equal scheduled_job, sent_out_calls.first.last
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
      jid: 'jid',
      child_job: 0
    }

    FakeThread.new(defaults.merge(attrs))
  end
end

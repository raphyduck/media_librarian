# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/media_librarian/services/base_service'

module MediaLibrarian
  module Services
    class SpeakerAdapterTest < Minitest::Test
      def test_tell_error_wraps_nil_options
        delegate = Minitest::Mock.new
        adapter = SpeakerAdapter.new(delegate)

        delegate.expect(:tell_error, nil, [:error, :context, { in_mail: nil }])

        adapter.tell_error(:error, :context)

        assert delegate.verify
      end

      def test_tell_error_wraps_boolean_options
        delegate = Minitest::Mock.new
        adapter = SpeakerAdapter.new(delegate)

        delegate.expect(:tell_error, nil, [:error, :context, { in_mail: false }, :extra])

        adapter.tell_error(:error, :context, false, :extra)

        assert delegate.verify
      end

      def test_tell_error_wraps_hash_options
        delegate = Minitest::Mock.new
        adapter = SpeakerAdapter.new(delegate)

        delegate.expect(:tell_error, nil, [:error, :context, { in_mail: true }])

        adapter.tell_error(:error, :context, { in_mail: true })

        assert delegate.verify
      end

      def test_daemon_send_delegates
        delegate = Class.new do
          attr_reader :calls

          def initialize
            @calls = []
          end

          def daemon_send(*args)
            @calls << args
          end

          def respond_to?(method_name, include_all = false)
            method_name == :daemon_send || super
          end
        end.new
        adapter = SpeakerAdapter.new(delegate)

        adapter.daemon_send(:run, :now)

        assert_equal [[:run, :now]], delegate.calls
      end

      def test_daemon_send_no_op_without_speaker
        adapter = SpeakerAdapter.new(nil)

        assert_nil adapter.daemon_send(:ignored)
      end
    end
  end
end

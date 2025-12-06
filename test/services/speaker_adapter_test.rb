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
    end
  end
end

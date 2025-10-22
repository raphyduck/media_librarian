# frozen_string_literal: true

# SimpleSpeaker expects mutable strings so it can adjust encodings when
# assembling email notifications.  Ruby 3 freezes string literals by
# default in many files across the project which resulted in
# `FrozenError: can't modify frozen String` exceptions whenever
# `Speaker#speak_up` forwarded such literals to the gem.  To keep the
# behaviour intact we duplicate string arguments before the gem mutates
# them.
if defined?(SimpleSpeaker::Speaker)
  module SimpleSpeaker
    class Speaker
      unless method_defined?(:medialibrarian_email_msg_add)
        alias_method :medialibrarian_email_msg_add, :email_msg_add

        def email_msg_add(message, type = nil)
          mutable_message = message.is_a?(String) ? message.dup : message
          medialibrarian_email_msg_add(mutable_message, type)
        end
      end
    end
  end
end

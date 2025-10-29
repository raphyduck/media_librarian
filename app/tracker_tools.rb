# frozen_string_literal: true

class TrackerTools
  include MediaLibrarian::AppContainerSupport

  class << self
    def login(tracker_name:, no_prompt: 0)
      raise ArgumentError, 'tracker_name is required' if tracker_name.to_s.strip.empty?

      MediaLibrarian::Services::TrackerLoginService
        .new(app: app)
        .login(tracker_name.to_s, no_prompt: no_prompt)
    end
  end
end

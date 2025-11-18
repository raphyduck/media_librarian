# frozen_string_literal: true

require 'date'

class CalendarFeed
  include MediaLibrarian::AppContainerSupport

  def self.refresh_feed(days: MediaLibrarian::Services::CalendarFeedService::DEFAULT_WINDOW_DAYS, limit: 100, sources: nil)
    window = days.to_i
    date_range = Date.today..(Date.today + window)
    calendar_service.refresh(date_range: date_range, limit: limit.to_i, sources: normalize_sources(sources))
  end

  def self.calendar_service
    @calendar_service ||= MediaLibrarian::Services::CalendarFeedService.new(app: app)
  end

  def self.normalize_sources(value)
    return nil if value.nil?

    Array(value).flat_map { |src| src.to_s.split(',') }
                .map { |src| src.strip.downcase }
                .reject(&:empty?)
  end
end

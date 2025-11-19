# frozen_string_literal: true

require 'date'
require_relative 'media_librarian/services/base_service'
require_relative 'media_librarian/services/calendar_feed_service'

class CalendarFeed
  include MediaLibrarian::AppContainerSupport

  DEFAULT_REFRESH_LIMIT = 100

  def self.refresh_feed(days: nil, limit: nil, sources: nil)
    config = calendar_config
    future_days = positive_integer(days) ||
                  positive_integer(config['future_days']) ||
                  positive_integer(config['window_future_days']) ||
                  positive_integer(config['refresh_days']) ||
                  MediaLibrarian::Services::CalendarFeedService::DEFAULT_WINDOW_DAYS
    past_days = positive_integer(config['past_days']) ||
                positive_integer(config['window_past_days']) ||
                0
    max_entries = positive_integer(limit) ||
                  positive_integer(config['refresh_limit']) ||
                  DEFAULT_REFRESH_LIMIT
    provider_list = normalize_sources(sources || config['providers'] || config['provider'])
    provider_list = nil if provider_list&.empty?

    today = Date.today
    date_range = (today - past_days)..(today + future_days)

    calendar_service.refresh(date_range: date_range, limit: max_entries, sources: provider_list)
  end

  def self.calendar_service
    @calendar_service ||= MediaLibrarian::Services::CalendarFeedService.new(app: app)
  end

  def self.normalize_sources(value)
    return nil if value.nil?

    Array(value).flat_map { |src| src.to_s.split(MediaLibrarian::Services::CalendarFeedService::SOURCES_SEPARATOR) }
                .map { |src| src.strip.downcase }
                .reject(&:empty?)
  end

  def self.calendar_config
    config = app.respond_to?(:config) ? app.config : nil
    section = config.is_a?(Hash) ? config['calendar'] : nil
    section.is_a?(Hash) ? section : {}
  end

  def self.positive_integer(value)
    return nil if value.nil?

    number = value.to_i
    number.positive? ? number : nil
  end
end

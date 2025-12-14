# frozen_string_literal: true

require 'date'
require 'yaml'
require_relative '../../../omdb_api'

module CalendarEntryEnricher
  class << self
    def enrich(entries)
      api = omdb_api
      raise StandardError, 'OMDb API configuration missing (set OMDB_API_KEY or config/omdb.api_key)' unless api

      entries.map { |entry| enrich_entry(entry.dup, api) }.compact
    end

    private

    def enrich_entry(entry, api)
      return entry unless entry.is_a?(Hash)

      imdb_id = imdb_identifier(entry)
      details = imdb_id ? api.title(imdb_id) : nil
      details ||= api.find_by_title(title: entry[:title], year: entry[:release_date]&.year, type: omdb_type(entry))
      return entry unless details.is_a?(Hash) && matches_title?(entry, details)

      ids = normalized_ids(entry)
      ids['imdb'] ||= details.dig(:ids, 'imdb') || details.dig('ids', 'imdb')
      entry[:ids] = ids unless ids.empty?
      entry[:rating] ||= details[:rating] || details['rating']
      entry[:imdb_votes] ||= details[:imdb_votes] || details['imdb_votes']
      entry[:poster_url] ||= details[:poster_url] || details['poster_url']
      entry[:backdrop_url] ||= details[:backdrop_url] || details['backdrop_url']
      entry[:release_date] ||= coerce_date(details[:release_date] || details['release_date'])

      entry[:genres] = details[:genres] if Array(entry[:genres]).empty? && array_present?(details[:genres])
      entry[:languages] = details[:languages] if Array(entry[:languages]).empty? && array_present?(details[:languages])
      entry[:countries] = details[:countries] if Array(entry[:countries]).empty? && array_present?(details[:countries])

      entry
    end

    def omdb_type(entry)
      case entry[:media_type].to_s.strip.downcase
      when 'movie', 'film' then 'movie'
      when 'series', 'show' then 'series'
      end
    end

    def imdb_identifier(entry)
      ids = normalized_ids(entry)
      [entry[:imdb_id], ids['imdb'], ids[:imdb], entry[:external_id]].map { |id| normalize_identifier(id) }.find do |candidate|
        candidate && candidate.match?(/\Aimdb\d+/i)
      end
    end

    def normalized_ids(entry)
      ids = entry[:ids] || {}
      return {} unless ids.is_a?(Hash)

      ids.each_with_object({}) { |(key, val), memo| memo[key.to_s] = val unless val.nil? }
    end

    def normalize_identifier(value)
      token = value.to_s.strip
      return nil if token.empty?

      token.start_with?('tt') ? "imdb#{token.delete_prefix('tt')}" : token
    end

    def matches_title?(entry, details)
      title = entry[:title].to_s.strip.downcase
      return false if title.empty?

      detail_title = details[:title] || details['title']
      detail_title.to_s.strip.downcase == title
    end

    def array_present?(value)
      Array(value).any? { |v| !v.to_s.strip.empty? }
    end

    def coerce_date(value)
      case value
      when Date
        value
      when Time, DateTime
        value.to_date
      else
        str = value.to_s.strip
        return nil if str.empty?

        Date.parse(str)
      end
    rescue ArgumentError
      nil
    end

    def omdb_api
      @omdb_api ||= begin
        config = load_config
        api_key = ENV['OMDB_API_KEY'] || config.dig('omdb', 'api_key')
        base_url = config.dig('omdb', 'base_url') if config.is_a?(Hash)
        return nil unless api_key && !api_key.to_s.strip.empty?

        OmdbApi.new(api_key: api_key, base_url: base_url)
      end
    end

    def load_config
      path = File.expand_path('../../../../config/conf.yml', __dir__)
      return {} unless File.exist?(path)

      YAML.load_file(path) || {}
    rescue StandardError
      {}
    end
  end
end

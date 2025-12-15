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
      return entry unless details.is_a?(Hash) && matches_result?(entry, details, imdb_id)

      ids = normalized_ids(entry)
      ids['imdb'] ||= details.dig(:ids, 'imdb') || details.dig('ids', 'imdb')
      entry[:ids] = ids unless ids.empty?

      rating = details[:rating] || details['rating']
      entry[:rating] = rating unless rating.nil?

      votes = details[:imdb_votes] || details['imdb_votes']
      entry[:imdb_votes] = votes unless votes.nil?

      poster = details[:poster_url] || details['poster_url']
      entry[:poster_url] = poster unless poster.to_s.strip.empty?

      backdrop = details[:backdrop_url] || details['backdrop_url']
      entry[:backdrop_url] = backdrop unless backdrop.to_s.strip.empty?

      synopsis = details[:synopsis] || details['synopsis'] || details[:plot] || details['plot']
      entry[:synopsis] = synopsis unless synopsis.to_s.strip.empty?

      release_date = coerce_date(details[:release_date] || details['release_date'])
      entry[:release_date] = release_date if release_date

      genres = details[:genres]
      entry[:genres] = genres if array_present?(genres)

      languages = details[:languages]
      entry[:languages] = languages if array_present?(languages)

      countries = details[:countries]
      entry[:countries] = countries if array_present?(countries)

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
      [entry[:imdb_id], ids['imdb'], ids[:imdb], entry[:external_id]]
        .map { |id| normalize_identifier(id) }
        .find { |candidate| imdb_identifier?(candidate) }
    end

    def normalized_ids(entry)
      ids = entry[:ids] || {}
      return {} unless ids.is_a?(Hash)

      ids.each_with_object({}) { |(key, val), memo| memo[key.to_s] = val unless val.nil? }
    end

    def normalize_identifier(value)
      token = value.to_s.strip
      return nil if token.empty?

      digits = token.sub(/\A(?:imdb|tt)/i, '')
      return nil unless digits.match?(/\A\d+\z/)

      "tt#{digits}"
    end

    def imdb_identifier?(value)
      value.to_s.match?(/\Att\d+/i)
    end

    def imdb_identifier?(value)
      value.to_s.match?(/\Att\d+/i)
    end

    def matches_result?(entry, details, imdb_id)
      detail_imdb = normalize_identifier(details.dig(:ids, 'imdb') || details.dig('ids', 'imdb') || details[:external_id] || details['external_id'])
      return true if imdb_identifier?(imdb_id) && !detail_imdb.to_s.empty? && detail_imdb.casecmp?(imdb_id)

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

# frozen_string_literal: true

require 'json'
require 'date'
require_relative 'support/calendar_entry_enricher'

module CalendarEntryEnrichmentHelpers
  module_function

  def normalize_entry(row)
    {
      id: row[:id],
      imdb_id: text_value(row[:imdb_id]),
      title: text_value(row[:title]),
      synopsis: text_value(row[:synopsis]),
      poster_url: text_value(row[:poster_url]),
      backdrop_url: text_value(row[:backdrop_url]),
      release_date: parse_date(row[:release_date]),
      genres: parse_list(row[:genres]),
      languages: parse_list(row[:languages]),
      countries: parse_list(row[:countries]),
      rating: row[:rating],
      imdb_votes: row[:imdb_votes],
      ids: parse_ids(row[:ids]),
      media_type: text_value(row[:media_type]),
      external_id: text_value(row[:external_id]),
      source: text_value(row[:source])
    }
  rescue StandardError
    nil
  end

  def needs_enrichment?(entry)
    blank_text?(entry[:title]) || blank_text?(entry[:poster_url]) || blank_text?(entry[:synopsis]) ||
      entry[:release_date].nil? || blank_list?(entry[:genres]) || blank_list?(entry[:languages]) ||
      blank_list?(entry[:countries]) || entry[:rating].nil? || entry[:imdb_votes].nil? || blank_ids?(entry[:ids])
  end

  def build_updates(original, enriched)
    updates = {}

    updates[:title] = enriched[:title] if blank_text?(original[:title]) && !blank_text?(enriched[:title])
    updates[:synopsis] = enriched[:synopsis] if blank_text?(original[:synopsis]) && !blank_text?(enriched[:synopsis])
    updates[:poster_url] = enriched[:poster_url] if blank_text?(original[:poster_url]) && !blank_text?(enriched[:poster_url])
    updates[:backdrop_url] = enriched[:backdrop_url] if blank_text?(original[:backdrop_url]) && !blank_text?(enriched[:backdrop_url])

    release_date = parse_date(enriched[:release_date])
    updates[:release_date] = release_date if original[:release_date].nil? && release_date

    updates[:genres] = JSON.generate(Array(enriched[:genres])) if blank_list?(original[:genres]) && array_present?(enriched[:genres])
    updates[:languages] = JSON.generate(Array(enriched[:languages])) if blank_list?(original[:languages]) && array_present?(enriched[:languages])
    updates[:countries] = JSON.generate(Array(enriched[:countries])) if blank_list?(original[:countries]) && array_present?(enriched[:countries])

    updates[:rating] = enriched[:rating].to_f if original[:rating].nil? && !enriched[:rating].nil?
    updates[:imdb_votes] = enriched[:imdb_votes].to_i if original[:imdb_votes].nil? && !enriched[:imdb_votes].nil?

    normalized_ids = normalize_ids(enriched[:ids])
    updates[:ids] = JSON.generate(normalized_ids) if blank_ids?(original[:ids]) && normalized_ids.any?
    imdb_id = text_value(enriched[:imdb_id])
    updates[:imdb_id] = imdb_id if blank_text?(original[:imdb_id]) && !imdb_id.empty?

    updates
  end

  def parse_ids(value)
    case value
    when Hash
      value.transform_keys(&:to_s)
    when String
      stripped = value.strip
      return {} if stripped.empty?

      parsed = JSON.parse(stripped)
      parsed.is_a?(Hash) ? parsed.transform_keys(&:to_s) : {}
    else
      {}
    end
  rescue JSON::ParserError
    {}
  end

  def normalize_ids(value)
    ids = parse_ids(value)
    ids['imdb'] = text_value(value[:imdb]) if value.is_a?(Hash) && ids['imdb'].to_s.empty?
    ids.transform_values { |val| text_value(val) }.reject { |_, val| val.empty? }
  end

  def parse_list(value)
    case value
    when Array
      value.map { |v| text_value(v) }.reject(&:empty?)
    when String
      stripped = value.strip
      return [] if stripped.empty?

      return JSON.parse(stripped).map { |v| text_value(v) }.reject(&:empty?) if stripped.start_with?('[')

      stripped.split(',').map { |v| text_value(v) }.reject(&:empty?)
    else
      []
    end
  rescue JSON::ParserError
    []
  end

  def parse_date(value)
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

  def text_value(value)
    value.to_s.strip
  end

  def blank_text?(value)
    text_value(value).empty?
  end

  def blank_list?(value)
    parse_list(value).empty?
  end

  def blank_ids?(value)
    parse_ids(value).empty?
  end

  def array_present?(value)
    Array(value).any? { |v| !text_value(v).empty? }
  end

  def deep_dup_entries(entries)
    entries.map { |entry| deep_dup(entry) }
  end

  def deep_dup(value)
    case value
    when Hash
      value.each_with_object({}) { |(k, v), memo| memo[k] = deep_dup(v) }
    when Array
      value.map { |v| deep_dup(v) }
    else
      value
    end
  end
end

Sequel.migration do
  up do
    helpers = CalendarEntryEnrichmentHelpers
    dataset = self[:calendar_entries]
    entries = dataset.map { |row| helpers.normalize_entry(row) }.compact
    candidates = entries.select { |entry| helpers.needs_enrichment?(entry) }
    unless candidates.empty?
      payload = helpers.deep_dup_entries(candidates)
      enriched = CalendarEntryEnricher.enrich(payload) || []
      original_by_id = candidates.each_with_object({}) { |entry, memo| memo[entry[:id]] = entry }

      unless enriched.all? { |entry| original_by_id[entry[:id]] == entry }
        enriched.each do |entry|
          original = original_by_id[entry[:id]]
          next unless original

          updates = helpers.build_updates(original, entry)
          next if updates.empty?

          dataset.where(id: entry[:id]).update(updates)
        end
      end
    end
  end

  down do
    # no-op; enrichment is additive
  end

end

#!/usr/bin/env ruby
# frozen_string_literal: true

ENV['SKIP_DB_MIGRATIONS'] ||= '1'

require 'bundler/setup'
require 'json'
require 'date'
require_relative '../lib/media_librarian/application'
require_relative '../lib/db/migrations/support/calendar_entry_enricher'

module CalendarEntriesEnrichment
  module Helpers
    module_function

    def normalize(row)
      {
        id: row[:id],
        imdb_id: text(row[:imdb_id]),
        title: text(row[:title]),
        synopsis: text(row[:synopsis]),
        poster_url: text(row[:poster_url]),
        backdrop_url: text(row[:backdrop_url]),
        release_date: parse_date(row[:release_date]),
        genres: parse_list(row[:genres]),
        languages: parse_list(row[:languages]),
        countries: parse_list(row[:countries]),
        rating: row[:rating],
        imdb_votes: row[:imdb_votes],
        ids: parse_ids(row[:ids]),
        media_type: text(row[:media_type]),
        external_id: text(row[:external_id]),
        source: text(row[:source])
      }
    rescue StandardError
      nil
    end

    def needs_enrichment?(entry)
      blank?(entry[:title]) || blank?(entry[:poster_url]) || blank?(entry[:synopsis]) ||
        entry[:release_date].nil? || entry[:genres].empty? || entry[:languages].empty? ||
        entry[:countries].empty? || entry[:rating].nil? || entry[:imdb_votes].nil? || entry[:ids].empty?
    end

    def updates_for(original, enriched)
      updates = {}
      updates[:title] = enriched[:title] if blank?(original[:title]) && present?(enriched[:title])
      updates[:synopsis] = enriched[:synopsis] if blank?(original[:synopsis]) && present?(enriched[:synopsis])
      updates[:poster_url] = enriched[:poster_url] if blank?(original[:poster_url]) && present?(enriched[:poster_url])
      updates[:backdrop_url] = enriched[:backdrop_url] if blank?(original[:backdrop_url]) && present?(enriched[:backdrop_url])

      release_date = parse_date(enriched[:release_date])
      updates[:release_date] = release_date if original[:release_date].nil? && release_date

      updates[:genres] = json_array(enriched[:genres]) if original[:genres].empty? && enriched[:genres].any?
      updates[:languages] = json_array(enriched[:languages]) if original[:languages].empty? && enriched[:languages].any?
      updates[:countries] = json_array(enriched[:countries]) if original[:countries].empty? && enriched[:countries].any?

      updates[:rating] = enriched[:rating].to_f if original[:rating].nil? && !enriched[:rating].nil?
      updates[:imdb_votes] = enriched[:imdb_votes].to_i if original[:imdb_votes].nil? && !enriched[:imdb_votes].nil?

      ids = normalize_ids(enriched[:ids])
      updates[:ids] = JSON.generate(ids) if original[:ids].empty? && ids.any?

      imdb_id = text(enriched[:imdb_id])
      updates[:imdb_id] = imdb_id if blank?(original[:imdb_id]) && present?(imdb_id)
      updates
    end

    def deep_dup(entries)
      entries.map { |entry| Marshal.load(Marshal.dump(entry)) }
    end

    def json_array(value)
      JSON.generate(Array(value))
    end

    def parse_ids(value)
      case value
      when Hash
        value.transform_keys(&:to_s)
      when String
        trimmed = value.strip
        return {} if trimmed.empty?

        parsed = JSON.parse(trimmed)
        parsed.is_a?(Hash) ? parsed.transform_keys(&:to_s) : {}
      else
        {}
      end
    rescue JSON::ParserError
      {}
    end

    def normalize_ids(value)
      ids = parse_ids(value)
      ids['imdb'] = text(value[:imdb]) if value.is_a?(Hash) && ids['imdb'].to_s.empty?
      ids.transform_values { |val| text(val) }.reject { |_, val| val.empty? }
    end

    def parse_list(value)
      case value
      when Array
        value.map { |v| text(v) }.reject(&:empty?)
      when String
        trimmed = value.strip
        return [] if trimmed.empty?

        return JSON.parse(trimmed).map { |v| text(v) }.reject(&:empty?) if trimmed.start_with?('[')

        trimmed.split(',').map { |v| text(v) }.reject(&:empty?)
      else
        []
      end
    rescue JSON::ParserError
      []
    end

    def parse_date(value)
      case value
      when Date then value
      when Time, DateTime then value.to_date
      else
        str = value.to_s.strip
        return nil if str.empty?

        Date.parse(str)
      end
    rescue ArgumentError
      nil
    end

    def text(value)
      value.to_s.strip
    end

    def blank?(value)
      text(value).empty?
    end

    def present?(value)
      !blank?(value)
    end
  end

  module_function

  def run(db, out: $stdout)
    dataset = db[:calendar_entries]
    entries = dataset.map { |row| Helpers.normalize(row) }.compact
    candidates = entries.select { |entry| Helpers.needs_enrichment?(entry) }
    return out.puts('No calendar entries need enrichment.') if candidates.empty?

    enriched = CalendarEntryEnricher.enrich(Helpers.deep_dup(candidates)) || []
    originals = candidates.each_with_object({}) { |entry, memo| memo[entry[:id]] = entry }

    updated = 0
    enriched.each do |entry|
      original = originals[entry[:id]]
      next unless original

      updates = Helpers.updates_for(original, entry)
      next if updates.empty?

      dataset.where(id: entry[:id]).update(updates)
      updated += 1
    end

    out.puts("Updated #{updated} calendar entr#{updated == 1 ? 'y' : 'ies'}.")
  end
end

if $PROGRAM_NAME == __FILE__
  app = MediaLibrarian.application
  CalendarEntriesEnrichment.run(app.db)
end

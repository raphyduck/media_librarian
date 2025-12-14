#!/usr/bin/env ruby
# frozen_string_literal: true

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

    def updates_for(original, enriched)
      updates = {}
      updates[:title] = enriched[:title] if present?(enriched[:title]) && enriched[:title] != original[:title]

      synopsis = text(enriched[:synopsis])
      updates[:synopsis] = synopsis if present?(synopsis) && synopsis != original[:synopsis]

      poster_url = text(enriched[:poster_url])
      updates[:poster_url] = poster_url if present?(poster_url) && poster_url != original[:poster_url]

      backdrop_url = text(enriched[:backdrop_url])
      updates[:backdrop_url] = backdrop_url if present?(backdrop_url) && backdrop_url != original[:backdrop_url]

      release_date = parse_date(enriched[:release_date])
      updates[:release_date] = release_date if release_date && release_date != original[:release_date]

      genres = Array(enriched[:genres])
      updates[:genres] = json_array(genres) if genres.any? && genres != Array(original[:genres])

      languages = Array(enriched[:languages])
      updates[:languages] = json_array(languages) if languages.any? && languages != Array(original[:languages])

      countries = Array(enriched[:countries])
      updates[:countries] = json_array(countries) if countries.any? && countries != Array(original[:countries])

      updates[:rating] = enriched[:rating].to_f if !enriched[:rating].nil? && enriched[:rating].to_f != original[:rating]
      updates[:imdb_votes] = enriched[:imdb_votes].to_i if !enriched[:imdb_votes].nil? && enriched[:imdb_votes].to_i != original[:imdb_votes]

      ids = normalize_ids(enriched[:ids])
      updates[:ids] = JSON.generate(ids) if ids.any? && ids != normalize_ids(original[:ids])

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
    dataset = db.database[:calendar_entries]
    entries = dataset.map { |row| Helpers.normalize(row) }.compact
    out.puts("Scanning #{entries.size} calendar entr#{entries.size == 1 ? 'y' : 'ies'}...")
    return out.puts('No calendar entries need enrichment.') if entries.empty?

    out.puts("Enriching #{entries.size} entr#{entries.size == 1 ? 'y' : 'ies'} via OMDb...")
    enriched = CalendarEntryEnricher.enrich(Helpers.deep_dup(entries)) || []
    originals = entries.each_with_object({}) { |entry, memo| memo[entry[:id]] = entry }

    updated = 0
    enriched.each do |entry|
      original = originals[entry[:id]]
      next unless original

      updates = Helpers.updates_for(original, entry)
      if updates.empty?
        out.puts("No updates needed for entry #{entry[:id]} (#{entry[:title]}).")
        next
      end

      dataset.where(id: entry[:id]).update(updates)
      out.puts("Updated entry #{entry[:id]} (#{entry[:title]}) with #{updates.keys.join(', ')}.")
      updated += 1
    end

    out.puts("Updated #{updated} calendar entr#{updated == 1 ? 'y' : 'ies'}.")
  end
end

if $PROGRAM_NAME == __FILE__
  app = MediaLibrarian.application
  CalendarEntriesEnrichment.run(app.db)
end

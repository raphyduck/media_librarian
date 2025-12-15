#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Enrich blank calendar entries using OMDb metadata.
#
# Usage:
#   bundle exec ruby scripts/enrich_calendar_entries.rb [--limit N] [--verbose]
#
# Options:
#   --limit N   Only process the first N matching rows (defaults to all).
#   --verbose   Print selected rows, OMDb request/response details, and update outcomes.
#
# The script exits early if OMDb credentials are missing, reusing CalendarEntryEnricher
# error handling.

require 'bundler/setup'
require 'optparse'
require 'date'

require_relative '../lib/media_librarian/application'
require_relative '../lib/db/migrations/support/calendar_entry_enricher'

options = { limit: nil, verbose: false }
OptionParser.new do |opts|
  opts.banner = 'Usage: bundle exec ruby scripts/enrich_calendar_entries.rb [options]'
  opts.on('--limit N', Integer, 'Maximum number of rows to process') { |n| options[:limit] = n }
  opts.on('--verbose', 'Enable verbose logging') { options[:verbose] = true }
end.parse!(ARGV)

app = MediaLibrarian.application
rows = Array(app.db.get_rows(:calendar_entries))

coerce_date = ->(value) { CalendarEntryEnricher.send(:coerce_date, value) }

def release_year_missing?(value)
  return true if value.nil?

  str = value.respond_to?(:to_date) ? value.to_date.to_s : value.to_s
  str.strip.empty? || !str.match?(/\d{4}/)
rescue StandardError
  true
end

def missing_value?(value)
  return true if value.nil?
  return value.strip.empty? if value.is_a?(String)
  return value.empty? if value.respond_to?(:empty?)

  false
end

def title_needs_enrichment?(row)
  title = row[:title].to_s.strip
  imdb = row[:imdb_id].to_s.strip
  title.empty? || (!imdb.empty? && title.casecmp(imdb).zero?)
rescue StandardError
  true
end

selected = rows.select do |row|
  title_needs_enrichment?(row) || release_year_missing?(row[:release_date])
end
selected = selected.first(options[:limit]) if options[:limit]&.positive?

if selected.empty?
  puts 'No calendar entries need enrichment.'
  exit(0)
end

api = nil
begin
  selected.each do |row|
    puts "Processing ##{row[:id]}: #{row[:title].inspect} (imdb_id=#{row[:imdb_id]})" if options[:verbose]

    entry = row.dup
    entry[:release_date] = coerce_date.call(row[:release_date])

    enriched = CalendarEntryEnricher.enrich([entry]).first
    api ||= CalendarEntryEnricher.send(:omdb_api) if CalendarEntryEnricher.respond_to?(:omdb_api, true)

    if options[:verbose]
      puts "  OMDb request: #{api&.last_request_path}" if api&.last_request_path
      puts "  OMDb response: #{api&.last_response_body}" if api&.last_response_body
    end

    unless enriched
      puts '  No enrichment data found.' if options[:verbose]
      next
    end

    updates = {}
    needs_title = title_needs_enrichment?(row)
    updates[:title] = enriched[:title] if needs_title && enriched[:title]
    updates[:release_date] = coerce_date.call(enriched[:release_date]) if release_year_missing?(row[:release_date]) && enriched[:release_date]

    existing_ids = row[:ids].is_a?(Hash) ? row[:ids] : {}
    enriched_ids = enriched[:ids].is_a?(Hash) ? enriched[:ids] : {}
    merged_ids = existing_ids.each_with_object({}) { |(k, v), memo| memo[k.to_s] = v }
    enriched_ids.each { |k, v| merged_ids[k.to_s] ||= v }
    imdb_value = merged_ids['imdb'] || merged_ids[:imdb] || enriched[:imdb_id]
    merged_ids['imdb'] ||= imdb_value if imdb_value
    updates[:ids] = merged_ids if merged_ids.any? && merged_ids != row[:ids]
    updates[:imdb_id] = imdb_value if missing_value?(row[:imdb_id]) && imdb_value

    %i[rating imdb_votes poster_url backdrop_url synopsis genres languages countries].each do |key|
      value = enriched[key]
      updates[key] = value if missing_value?(row[key]) && !missing_value?(value)
    end

    if updates.empty?
      puts '  No updates applied.' if options[:verbose]
      next
    end

    app.db.update_rows(:calendar_entries, updates, id: row[:id])
    puts "  Updated: #{updates.keys.join(', ')}" if options[:verbose]
  end
rescue StandardError => e
  warn e.message
  exit(1)
end

puts 'Enrichment complete.'

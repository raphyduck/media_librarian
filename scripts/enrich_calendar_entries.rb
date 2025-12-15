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

def missing_value?(value)
  return true if value.nil?
  return value.strip.empty? if value.is_a?(String)
  return value.empty? if value.respond_to?(:empty?)

  false
end

def missing_release_date?(value)
  date = coerce_date(value)
  date.nil? || !date.respond_to?(:year)
end

def title_matches_imdb_id?(row)
  title = row[:title].to_s.strip
  imdb = row[:imdb_id].to_s.strip
  !title.empty? && !imdb.empty? && title.casecmp?(imdb)
end

selected = rows.select do |row|
  row[:title].to_s.strip.empty? || missing_release_date?(row[:release_date]) || title_matches_imdb_id?(row)
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
    entry[:release_date] = coerce_date(row[:release_date])

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
    updates[:title] = enriched[:title] if enriched[:title]
    updates[:release_date] = coerce_date(enriched[:release_date]) if enriched[:release_date]

    existing_ids = row[:ids].is_a?(Hash) ? row[:ids] : {}
    enriched_ids = enriched[:ids].is_a?(Hash) ? enriched[:ids] : {}
    merged_ids = existing_ids.each_with_object({}) { |(k, v), memo| memo[k.to_s] = v }
    enriched_ids.each { |k, v| merged_ids[k.to_s] = v }
    imdb_value = merged_ids['imdb'] || merged_ids[:imdb] || enriched[:imdb_id]
    merged_ids['imdb'] ||= imdb_value if imdb_value
    updates[:ids] = merged_ids if merged_ids.any? && merged_ids != row[:ids]

    %i[rating imdb_votes poster_url backdrop_url synopsis genres languages countries].each do |key|
      value = enriched[key]
      updates[key] = value if !missing_value?(value)
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

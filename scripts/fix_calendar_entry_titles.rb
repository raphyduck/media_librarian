#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Fix calendar entries whose titles match their external identifiers.
#
# Usage:
#   bundle exec ruby scripts/fix_calendar_entry_titles.rb [--dry-run] [--verbose]
#
# Requires OMDb credentials to fetch real titles via IMDb IDs:
#   - OMDB_API_KEY (env var), or
#   - ~/.medialibrarian/conf.yml with omdb.api_key
#
# If enrichment fails, the script deletes the calendar entry (and watchlist
# rows referencing the same ids) and logs the row for manual review.

require 'bundler/setup'
require 'optparse'
require_relative '../lib/media_librarian/application'
require_relative '../lib/omdb_api'
require_relative '../app/media_librarian/services/calendar_feed_service'

options = { dry_run: false, verbose: false }
OptionParser.new do |opts|
  opts.banner = 'Usage: bundle exec ruby scripts/fix_calendar_entry_titles.rb [options]'
  opts.on('--dry-run', 'Do not update/delete records') { options[:dry_run] = true }
  opts.on('--verbose', 'Print per-row details') { options[:verbose] = true }
end.parse!(ARGV)

app = MediaLibrarian.application
db = app.db

rows = Array(db.get_rows(:calendar_entries))

api = begin
  config = app.config || {}
  api_key = ENV['OMDB_API_KEY'] || config.dig('omdb', 'api_key')
  base_url = config.dig('omdb', 'base_url')
  api_key.to_s.strip.empty? ? nil : OmdbApi.new(api_key: api_key, base_url: base_url)
rescue StandardError
  nil
end

def id_title_match?(title, value)
  title = title.to_s.strip
  value = value.to_s.strip
  return false if title.empty? || value.empty?

  title.casecmp?(value)
end

def enrich_title(row, api, app, db)
  imdb_id = row[:imdb_id].to_s.strip
  imdb_id = nil if imdb_id.empty?
  title = nil

  if api && imdb_id
    details = api.title(imdb_id)
    title = details[:title] || details['title'] if details
  end

  if title.to_s.strip.empty?
    enriched = MediaLibrarian::Services::CalendarFeedService.enrich_entries([row.dup], app: app, db: db)&.first
    title = enriched[:title] if enriched
  end

  title.to_s.strip.empty? ? nil : title
end

candidates = rows.select do |row|
  id_title_match?(row[:title], row[:external_id]) || id_title_match?(row[:title], row[:imdb_id])
end

if candidates.empty?
  puts 'No calendar entries need title fixes.'
  exit(0)
end

updated = 0
deleted = 0
flagged = 0

candidates.each do |row|
  puts "Candidate ##{row[:id]} title=#{row[:title].inspect} external_id=#{row[:external_id].inspect} imdb_id=#{row[:imdb_id].inspect}" if options[:verbose]
  new_title = enrich_title(row, api, app, db)
  if !new_title || id_title_match?(new_title, row[:external_id]) || id_title_match?(new_title, row[:imdb_id])
    puts "Needs review (delete): #{row.inspect}"
    flagged += 1
    unless options[:dry_run]
      db.delete_rows(:calendar_entries, { id: row[:id] })
      if db.table_exists?(:watchlist)
        db.delete_rows(:watchlist, { imdb_id: row[:imdb_id] }) unless row[:imdb_id].to_s.strip.empty?
        db.delete_rows(:watchlist, { external_id: row[:external_id] }) unless row[:external_id].to_s.strip.empty?
      end
    end
    deleted += 1
    next
  end

  unless options[:dry_run]
    db.update_rows(:calendar_entries, { title: new_title }, { id: row[:id] })
  end
  puts "Updated ##{row[:id]} -> #{new_title.inspect}" if options[:verbose]
  updated += 1
end

puts "Updated #{updated} calendar entr#{updated == 1 ? 'y' : 'ies'}, deleted #{deleted} (#{flagged} flagged)."

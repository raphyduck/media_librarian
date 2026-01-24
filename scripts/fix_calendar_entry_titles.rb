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
# If enrichment fails, the script deletes the calendar entry (and dependent
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

def dependent_external_id(row)
  title = row[:title].to_s.strip
  external_id = row[:external_id].to_s.strip
  external_id = '' if !external_id.empty? && !title.empty? && external_id.casecmp?(title)
  return external_id unless external_id.empty?

  ids = row[:ids].is_a?(Hash) ? row[:ids] : {}
  %i[imdb slug tmdb tvdb trakt].each do |key|
    value = ids[key] || ids[key.to_s]
    return value.to_s.strip unless value.to_s.strip.empty?
  end
  nil
end

def delete_dependents(db, row, dry_run, verbose)
  deps = { watchlist: %i[imdb_id external_id], local_media: %i[imdb_id] }
  external_id = dependent_external_id(row)
  deps.each do |table, cols|
    next unless db.table_exists?(table)

    cols.each do |col|
      value = col == :external_id ? external_id : row[col]
      next if value.to_s.strip.empty?

      puts "  deleting #{table} where #{col}=#{value.inspect}" if verbose
      db.delete_rows(table, { col => value }) unless dry_run
    end
  end
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
    end
    delete_dependents(db, row, options[:dry_run], options[:verbose])
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

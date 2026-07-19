#!/usr/bin/env ruby
# frozen_string_literal: true
#
# One-shot fix: rewrite calendar movie entries stored under their translated
# (usually English) title with the original title from TMDB. Entries sourced
# from Trakt/OMDb, and TMDB entries imported before the original-title
# preference, are the typical candidates. TMDB movie endpoints accept IMDb
# ids in place of TMDB ids, so entries lacking a tmdb id are resolved through
# their imdb_id.
#
# Usage:
#   bundle exec ruby scripts/fix_calendar_entry_original_titles.rb [--dry-run] [--verbose]
#
# Requires TMDB credentials in ~/.medialibrarian/conf.yml (tmdb.api_key).

require 'bundler/setup'
require 'optparse'
require 'themoviedb'
require_relative '../lib/media_librarian/application'

options = { dry_run: false, verbose: false }
OptionParser.new do |opts|
  opts.banner = 'Usage: bundle exec ruby scripts/fix_calendar_entry_original_titles.rb [options]'
  opts.on('--dry-run', 'Do not update records') { options[:dry_run] = true }
  opts.on('--verbose', 'Print per-row details') { options[:verbose] = true }
end.parse!(ARGV)

app = MediaLibrarian.application
db = app.db

api_key = begin
  config = app.config || {}
  ENV['TMDB_API_KEY'] || config.dig('tmdb', 'api_key')
rescue StandardError
  nil
end
abort 'Missing tmdb.api_key in configuration (or TMDB_API_KEY env var)' if api_key.to_s.strip.empty?
Tmdb::Api.key(api_key)

rows = Array(db.get_rows(:calendar_entries)).select { |row| row[:media_type].to_s == 'movie' }
updated = 0
unchanged = 0
skipped = 0
failed = 0

rows.each do |row|
  ids = row[:ids].is_a?(Hash) ? row[:ids] : {}
  # IMDb ids are unambiguous on TMDB; a stray non-TMDB numeric id stored under
  # the tmdb key would resolve to an unrelated movie, so prefer the imdb id.
  imdb_id = row[:imdb_id].to_s.strip
  imdb_id = (ids['imdb'] || ids[:imdb]).to_s.strip if imdb_id.empty?
  lookup_id = imdb_id.empty? ? (ids['tmdb'] || ids[:tmdb]) : imdb_id
  if lookup_id.to_s.strip.empty?
    puts "Skipping ##{row[:id]} #{row[:title].inspect}: no tmdb/imdb id" if options[:verbose]
    skipped += 1
    next
  end

  details = begin
    Tmdb::Movie.detail(lookup_id)
  rescue StandardError => e
    puts "Lookup failed for ##{row[:id]} #{row[:title].inspect} (#{lookup_id}): #{e.message}"
    failed += 1
    next
  end

  details = nil unless details.is_a?(Hash)
  detail_imdb = details ? (details['imdb_id'] || details.dig('external_ids', 'imdb_id')).to_s.strip : ''
  if details && !imdb_id.empty? && !detail_imdb.empty? && detail_imdb != imdb_id
    puts "Identity mismatch for ##{row[:id]} #{row[:title].inspect}: TMDB #{lookup_id} belongs to #{detail_imdb}, expected #{imdb_id}"
    failed += 1
    next
  end

  original = details ? details['original_title'].to_s.strip : ''
  if original.empty?
    puts "No TMDB match for ##{row[:id]} #{row[:title].inspect} (#{lookup_id})" if options[:verbose]
    failed += 1
    next
  end

  if original == row[:title].to_s.strip
    puts "Unchanged ##{row[:id]} #{row[:title].inspect}" if options[:verbose]
    unchanged += 1
    next
  end

  puts "##{row[:id]} #{row[:title].inspect} -> #{original.inspect}"
  db.update_rows(:calendar_entries, { title: original }, { id: row[:id] }) unless options[:dry_run]
  updated += 1
end

puts "#{options[:dry_run] ? '[dry-run] ' : ''}Updated #{updated}, unchanged #{unchanged}, skipped #{skipped}, failed #{failed} (of #{rows.length} movie entries)."

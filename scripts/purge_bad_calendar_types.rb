#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Remove calendar_entries with mismatched media types.
#
# Usage:
#   bundle exec ruby scripts/purge_bad_calendar_types.rb [--dry-run]

require 'bundler/setup'
require 'optparse'

require_relative '../lib/media_librarian/application'

options = { dry_run: false }
OptionParser.new do |opts|
  opts.banner = 'Usage: bundle exec ruby scripts/purge_bad_calendar_types.rb [options]'
  opts.on('--dry-run', 'List deletions without modifying data') { options[:dry_run] = true }
end.parse!(ARGV)

app = MediaLibrarian.application

def entry_media_type(row)
  row[:media_type] || row['media_type'] || row[:type] || row['type']
end

def entry_ids(row)
  ids = row[:ids] || row['ids']
  ids.is_a?(Hash) ? ids : {}
end

def build_tmdb_provider(app)
  config = app.config
  tmdb_config = config.is_a?(Hash) ? config['tmdb'] : nil
  return nil unless tmdb_config.is_a?(Hash)

  api_key = tmdb_config['api_key'].to_s
  return nil if api_key.empty? || api_key == 'api_key'

  MediaLibrarian::Services::CalendarFeedService::TmdbCalendarProvider.new(
    api_key: api_key,
    language: tmdb_config['language'] || tmdb_config['languages'],
    region: tmdb_config['region'],
    speaker: app.speaker
  )
end

def actual_type_for(row, service, omdb_api, tmdb_provider)
  entry = {
    imdb_id: row[:imdb_id] || row['imdb_id'],
    ids: entry_ids(row),
    external_id: row[:external_id] || row['external_id'],
    title: row[:title] || row['title'],
    release_date: row[:release_date] || row['release_date'],
    media_type: entry_media_type(row)
  }

  if omdb_api
    imdb_id = service.send(:imdb_id_for, entry)
    details = imdb_id ? service.send(:omdb_details, omdb_api, imdb_id) : nil
    return details[:media_type] if details && details[:media_type]
  end

  if tmdb_provider
    tmdb_id = entry[:ids][:tmdb] || entry[:ids]['tmdb']
    if tmdb_id
      return 'movie' if tmdb_provider.send(:fetch_details, :movie, tmdb_id)
      return 'show' if tmdb_provider.send(:fetch_details, :tv, tmdb_id)
    end
  end

  nil
rescue StandardError
  nil
end

def dependent_tables(db)
  return {} unless db&.database

  db.database.tables.each_with_object({}) do |table, memo|
    next if table.to_sym == :calendar_entries

    begin
      fks = db.database.foreign_key_list(table).filter_map do |fk|
        next unless fk[:table].to_sym == :calendar_entries

        Array(fk[:columns] || fk[:key]).compact.map(&:to_sym)
      end.flatten.uniq
    rescue StandardError
      fks = []
    end

    memo[table.to_sym] = fks if fks.any?
  end
end

db = app.db
unless db&.table_exists?(:calendar_entries)
  warn 'calendar_entries table not available.'
  exit(1)
end

rows = Array(db.get_rows(:calendar_entries))
service = MediaLibrarian::Services::CalendarFeedService.new(app: app, db: db)
omdb_api = service.send(:omdb_detail_api)
tmdb_provider = build_tmdb_provider(app)

dependents = dependent_tables(db)

incorrect = rows.filter_map do |row|
  expected = actual_type_for(row, service, omdb_api, tmdb_provider)
  next unless expected

  current = entry_media_type(row).to_s
  next if Utils.regularise_media_type(expected.to_s) == Utils.regularise_media_type(current)

  { row: row, expected: expected, current: current }
end

if incorrect.empty?
  puts 'No incorrect calendar entries found.'
  exit(0)
end

incorrect.each do |item|
  row = item[:row]
  id = row[:id]
  imdb_id = row[:imdb_id] || row['imdb_id']
  external_id = row[:external_id] || row['external_id']
  title = row[:title] || row['title']
  touched = dependents.keys + [:calendar_entries]

  puts [
    "id=#{id}",
    "imdb_id=#{imdb_id}",
    "external_id=#{external_id}",
    "title=#{title.inspect}",
    "expected=#{item[:expected]}",
    "current=#{item[:current]}",
    "tables=#{touched.join(',')}"
  ].join(' | ')

  next if options[:dry_run]

  dependents.each do |table, columns|
    columns.each { |column| db.delete_rows(table, { column => id }) }
  end
  db.delete_rows(:calendar_entries, { id: id })
end

puts(options[:dry_run] ? 'Dry run complete.' : 'Purge complete.')

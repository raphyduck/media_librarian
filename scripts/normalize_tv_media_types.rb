#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require_relative '../lib/media_librarian/application'

PREFIXES = %w[tv% series%].freeze
TARGET = 'show'

def rows_for_prefixes(db, table)
  PREFIXES.flat_map { |pattern| db.get_rows(table, {}, { 'media_type ilike' => pattern }) }
end

def normalize_table(db, table)
  rows = rows_for_prefixes(db, table).uniq { |row| row[:id] }
  updated = rows.sum do |row|
    next 0 if row[:media_type].to_s.strip.casecmp?(TARGET)

    db.update_rows(table, { media_type: TARGET }, { id: row[:id] }).to_i
    1
  end
  puts "#{table}: #{updated}/#{rows.size} updated."
  updated
end

app = MediaLibrarian.application

begin
  total = %i[calendar_entries local_media].sum { |table| normalize_table(app.db, table) }
  puts(total.positive? ? "Normalized #{total} row(s)." : 'No rows needed normalization.')
  exit(0)
rescue StandardError => e
  warn(e.message)
  exit(1)
end

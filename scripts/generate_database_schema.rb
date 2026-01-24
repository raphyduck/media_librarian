#!/usr/bin/env ruby
# frozen_string_literal: true

require 'sequel'
require 'tmpdir'

MIGRATIONS_PATH = File.expand_path('../lib/db/migrations', __dir__)
OUTPUT_PATH = File.expand_path('../docs/database_schema.md', __dir__)

Sequel.extension :migration

LOGICAL_FOREIGN_KEYS = {
  calendar_entries: [
    {
      column: 'imdb_id',
      references: 'watchlist.imdb_id',
      description: 'Shared IMDb identifier for the same title.'
    },
    {
      column: 'imdb_id',
      references: 'local_media.imdb_id',
      description: 'Local media files for the same title.'
    }
  ],
  watchlist: [
    {
      column: 'imdb_id',
      references: 'calendar_entries.imdb_id',
      description: 'Calendar metadata for the same title.'
    },
    {
      column: 'imdb_id',
      references: 'local_media.imdb_id',
      description: 'Local media files for the same title.'
    }
  ],
  local_media: [
    {
      column: 'imdb_id',
      references: 'calendar_entries.imdb_id',
      description: 'Calendar metadata for the same title.'
    },
    {
      column: 'imdb_id',
      references: 'watchlist.imdb_id',
      description: 'Watchlist entry for the same title.'
    }
  ]
}.freeze

def format_default(value)
  value.nil? ? '' : value.inspect
end

def format_columns(schema)
  schema.map do |(column, details)|
    {
      name: column.to_s,
      type: details[:db_type],
      null: details.fetch(:allow_null, true) ? 'YES' : 'NO',
      default: format_default(details[:default]),
      primary_key: details[:primary_key] ? 'YES' : ''
    }
  end
end

def format_indexes(indexes)
  indexes.map do |name, details|
    {
      name: name.to_s,
      columns: details[:columns].map(&:to_s).join(', '),
      unique: details[:unique] ? 'YES' : 'NO'
    }
  end
end

Dir.mktmpdir('media_librarian_schema') do |dir|
  db = Sequel.sqlite(File.join(dir, 'schema.sqlite3'))
  Sequel::Migrator.run(db, MIGRATIONS_PATH)

  lines = []
  lines << '# Database schema'
  lines << ''
  lines << 'Regenerate with:'
  lines << '```sh'
  lines << 'bundle exec ruby scripts/generate_database_schema.rb'
  lines << '```'
  lines << ''

  db.tables.sort.each do |table|
    schema = format_columns(db.schema(table))
    indexes = format_indexes(db.indexes(table))
    foreign_keys = db.foreign_key_list(table)
    logical_fks = LOGICAL_FOREIGN_KEYS.fetch(table.to_sym, [])

    lines << "## #{table}"
    lines << ''
    lines << '| Column | Type | Null | Default | PK |'
    lines << '| --- | --- | --- | --- | --- |'
    schema.each do |column|
      lines << "| #{column[:name]} | #{column[:type]} | #{column[:null]} | #{column[:default]} | #{column[:primary_key]} |"
    end
    lines << ''

    lines << '### Indexes'
    if indexes.empty?
      lines << '_None_'
    else
      lines << ''
      lines << '| Name | Columns | Unique |'
      lines << '| --- | --- | --- |'
      indexes.each do |index|
        lines << "| #{index[:name]} | #{index[:columns]} | #{index[:unique]} |"
      end
    end
    lines << ''

    lines << '### Foreign keys (database)'
    if foreign_keys.empty?
      lines << '_None_'
    else
      lines << ''
      lines << '| Columns | References |'
      lines << '| --- | --- |'
      foreign_keys.each do |fk|
        columns = Array(fk[:columns]).map(&:to_s).join(', ')
        target = [fk[:table], Array(fk[:key]).join(', ')].join('.')
        lines << "| #{columns} | #{target} |"
      end
    end
    lines << ''

    lines << '### Foreign keys (logical)'
    if logical_fks.empty?
      lines << '_None_'
    else
      lines << ''
      lines << '| Column | References | Notes |'
      lines << '| --- | --- | --- |'
      logical_fks.each do |fk|
        lines << "| #{fk[:column]} | #{fk[:references]} | #{fk[:description]} |"
      end
    end
    lines << ''
  end

  File.write(OUTPUT_PATH, lines.join("\n"))
end

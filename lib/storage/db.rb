# frozen_string_literal: true

require 'json'
require 'sequel'
require 'time'
require 'date'

Sequel.extension :migration

module Storage
  class Db
    attr_reader :database

    def initialize(db_path, readonly = 0, migrations_path: default_migrations_path)
      @readonly = readonly.to_i.positive?
      @database = Sequel.connect(adapter: 'sqlite', database: db_path, readonly: @readonly)
      run_migrations(migrations_path) unless @readonly
    rescue StandardError => e
      log_error(e)
      raise
    end

    def delete_rows(table, conditions = {}, additionals = {})
      dataset = build_dataset(table, conditions, additionals)
      sql = dataset.delete_sql
      run_write(table, sql) { dataset.delete }
    rescue StandardError => e
      log_error(e)
      nil
    end

    def dump_schema
      database.tables.each_with_object({}) do |table_name, schema|
        schema[table_name] = database.schema(table_name).each_with_object({}) do |(column, details), memo|
          memo[column] = details[:db_type]
        end
      end
    end

    def execute(raw_sql)
      log_sql(raw_sql)
      return if skip_write?(raw_sql)

      database.run(raw_sql)
    end

    def get_main_column(table)
      case table.to_s
      when 'torrents'
        :name
      when 'metadata_search'
        :keywords
      else
        nil
      end
    end

    def get_rows(table, conditions = {}, additionals = {})
      dataset = build_dataset(table, conditions, additionals)
      log_sql(dataset.sql)
      rows = Utils.lock_block("db_#{table}") { dataset.all }
      rows.map { |row| deserialize_row(row) }
    rescue StandardError => e
      log_error(e)
      []
    end

    def insert_row(table, values, or_replace = 0)
      dataset = dataset_for(table)
      dataset = dataset.insert_conflict(:replace) if or_replace.to_i.positive?
      prepared = prepare_values(table, values)
      sql = dataset.insert_sql(prepared)
      run_write(table, sql) { dataset.insert(prepared) }
    rescue StandardError => e
      log_error(e)
      nil
    end

    def insert_rows(table, rows, replace_existing = false)
      return true if rows.empty?

      if replace_existing
        rows.each { |values| insert_row(table, values, 1) }
        return true
      end

      dataset = dataset_for(table)
      prepared_rows = rows.map { |values| prepare_values(table, values) }
      sql = Array(dataset.multi_insert_sql(prepared_rows)).join('; ')
      run_write(table, sql) { dataset.multi_insert(prepared_rows) }
      true
    rescue StandardError => e
      log_error(e)
      false
    end

    def setup(_db_path, _readonly = 0)
      # Migrations are handled during initialization.
    end

    def touch_rows(table, conditions, additionals = {})
      update_rows(table, {}, conditions, additionals)
    end

    def update_rows(table, values, conditions, additionals = {})
      dataset = build_dataset(table, conditions, additionals)
      prepared = prepare_values(table, values, true)
      return 0 if prepared.empty?
      sql = dataset.update_sql(prepared)
      run_write(table, sql) { dataset.update(prepared) }
    rescue StandardError => e
      log_error(e)
      nil
    end

    def table_exists?(table)
      database.table_exists?(table.to_sym)
    end

    private

    attr_reader :readonly

    def build_dataset(table, conditions = {}, additionals = {})
      dataset = dataset_for(table)
      conditions.each do |column, value|
        dataset = dataset.where(column.to_sym => value)
      end
      additionals.each do |key, value|
        dataset = apply_additional_filter(dataset, key, value)
      end
      dataset
    end

    def apply_additional_filter(dataset, key, value)
      if key.is_a?(String)
        column, operator = parse_operator(key)
        return dataset.where(column => value) if operator == :eq
        return dataset.exclude(column => value) if operator == :ne
        return dataset.where(Sequel.like(column, value)) if operator == :like
        return dataset.where(Sequel.ilike(column, value)) if operator == :ilike
        if %i[gt gte lt lte].include?(operator)
          comparison_method = {
            gt: :>,
            gte: :>=,
            lt: :<,
            lte: :<=
          }.fetch(operator)
          return dataset.where(Sequel.expr(column).public_send(comparison_method, value))
        end
      end
      dataset.where(normalize_key(key) => value)
    end

    def dataset_for(table)
      database[table.to_sym]
    end

    def default_migrations_path
      File.expand_path('../db/migrations', __dir__)
    end

    def deserialize_row(row)
      row.each_with_object({}) do |(column, value), memo|
        memo[column] = deserialize_value(value)
      end
    end

    def deserialize_value(value)
      case value
      when Time, Date, DateTime
        value.iso8601
      when String
        parse_json(value)
      else
        value
      end
    end

    def parse_json(value)
      stripped = value.strip
      return value if stripped.empty?
      return JSON.parse(stripped, symbolize_names: true) if stripped.start_with?('{', '[')

      value
    rescue JSON::ParserError
      value
    end

    def prepare_values(table, values, update_only = false)
      hash_values = normalize_values(table, values)
      schema = schema_info(table)

      if schema.key?(:created_at) && !update_only && !hash_values.key?(:created_at)
        hash_values[:created_at] = current_timestamp
      end

      if schema.key?(:updated_at) && !hash_values.key?(:updated_at)
        hash_values[:updated_at] = current_timestamp
      elsif update_only && hash_values.empty? && schema.key?(:updated_at)
        hash_values[:updated_at] = current_timestamp
      end

      hash_values.transform_values { |value| serialize_value(value) }
    end

    def normalize_values(table, values)
      case values
      when Hash
        values.each_with_object({}) do |(key, value), memo|
          memo[key.to_sym] = value
        end
      when Array
        columns = schema_info(table).keys
        Hash[columns.zip(values)].compact
      else
        {}
      end
    end

    def serialize_value(value)
      case value
      when Hash, Array
        JSON.generate(value)
      when Time, Date, DateTime
        value.iso8601
      else
        value
      end
    end

    def current_timestamp
      Time.now.utc.iso8601
    end

    def schema_info(table)
      @schema_cache ||= {}
      @schema_cache[table.to_sym] ||= database.schema(table.to_sym).each_with_object({}) do |(column, info), memo|
        memo[column] = info
      end
    end

    def parse_operator(key)
      match = key.to_s.strip.match(/^(\w+)\s*(=|!=|<>|>=|<=|>|<|like|ilike)$/i)
      return [match[1].to_sym, operator_symbol(match[2].downcase)] if match

      [normalize_key(key), :eq]
    end

    def operator_symbol(operator)
      {
        '=' => :eq,
        '!=' => :ne,
        '<>' => :ne,
        '>' => :gt,
        '<' => :lt,
        '>=' => :gte,
        '<=' => :lte,
        'like' => :like,
        'ilike' => :ilike
      }.fetch(operator, :eq)
    end

    def run_migrations(path)
      return unless path && Dir.exist?(path)

      Sequel::Migrator.run(database, path)
    end

    def normalize_key(key)
      key.is_a?(String) ? key.strip.to_sym : key
    end

    def run_write(table, sql)
      log_sql(sql, write: true)
      return speaker&.speak_up("Would #{sql}") if Env.pretend?
      raise 'ReadOnly Db' if readonly

      Utils.lock_block("db_#{table}") { yield }
    end

    def skip_write?(sql)
      return false unless Env.pretend?

      speaker&.speak_up("Would #{sql}")
      true
    end

    def log_sql(sql, write: false)
      return if sql.to_s.empty?
      speaker&.speak_up("Executing SQL query: '#{sql}'", 0) if Env.debug?
    end

    def log_error(error, sql = nil)
      context = sql ? { query: sql } : {}
      speaker&.tell_error(error, Utils.arguments_dump(binding, 2, 'Storage::Db', context))
    end

    def speaker
      return unless defined?(MediaLibrarian)
      app = MediaLibrarian.respond_to?(:app) ? MediaLibrarian.app : nil
      app&.speaker
    rescue StandardError
      nil
    end
  end
end

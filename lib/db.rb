# Database schema definition
DB_SCHEMA = {
  queues_state: {
    columns: {
      queue_name: 'varchar(200) primary key',
      value: 'text',
      created_at: 'datetime'
    }
  },
  media_lists: {
    columns: {
      list_name: 'text',
      type: 'text',
      title: 'text',
      year: 'integer',
      alt_titles: 'text',
      url: 'text',
      imdb: 'text',
      tmdb: 'text',
      created_at: 'datetime'
    },
    unique: [:list_name, :title, :year, :imdb]
  },
  metadata_search: {
    columns: {
      keywords: 'text',
      type: 'integer',
      result: 'text',
      created_at: 'datetime'
    },
    unique: [:keywords, :type]
  },
  torrents: {
    columns: {
      name: 'varchar(500) primary key',
      identifier: 'text',
      identifiers: 'text',
      tattributes: 'text',
      created_at: 'datetime',
      updated_at: 'datetime',
      waiting_until: 'datetime',
      torrent_id: 'text',
      status: 'integer'
    },
    unique: [:torrent_id]
  },
  trakt_auth: {
    columns: {
      account: 'varchar(30) primary key',
      access_token: 'varchar(200)',
      token_type: 'varchar(200)',
      refresh_token: 'varchar(200)',
      scope: 'varchar(200)',
      created_at: 'integer',
      expires_in: 'integer'
    }
  }
}.freeze

module Storage
  class Db
    def initialize(db_path, readonly = 0)
      @s_db = SQLite3::Database.new(db_path) unless @s_db
      setup(db_path, readonly)
      @readonly = readonly
    end

    def delete_rows(table, conditions = {}, additionals = {})
      query = "DELETE FROM #{table}"
      query << prepare_conditions(conditions, additionals)
      values = conditions.values + additionals.values

      execute_query(table, query, values)
    rescue => e
      log_error(e)
      nil
    end

    def dump_schema
      schema = {}
      get_rows('sqlite_master', { type: 'table' }).each do |table|
        schema[table[:name].to_sym] = table_columns(table[:name])
      end
      schema
    end

    def execute(raw_sql)
      @s_db.execute(raw_sql)
    end

    def get_main_column(table)
      case table
      when 'torrents'
        :name
      when 'metadata_search'
        :keywords
      else
        nil
      end
    end

    def get_rows(table, conditions = {}, additionals = {})
      query = "SELECT * FROM #{table}"
      query << prepare_conditions(conditions, additionals)
      values = conditions.values.map(&:to_s) + additionals.values.map(&:to_s)

      result = execute_query(table, query, values, 0)

      result.map do |row|
        columns = table_columns(table)
        row_hash = {}

        columns.each_with_index do |(column_name, _), index|
          value = row[index]
          # Parse JSON/Array-like strings
          if value.is_a?(String) && value.match?(/^[{\[].*[}\]]$/)
            value = eval(value) rescue value
          end
          row_hash[column_name.to_sym] = value
        end

        row_hash
      end
    rescue => e
      log_error(e)
      []
    end

    def insert_row(table, values, or_replace = 0)
      prepared_values = prepare_values(table, values)
      columns = prepared_values.keys.map(&:to_s).join(',')
      placeholders = Array.new(prepared_values.size, '?').join(',')

      query = "INSERT#{' OR REPLACE' if or_replace.to_i > 0} INTO #{table} (#{columns}) VALUES (#{placeholders})"
      execute_query(table, query, prepared_values.values.map(&:to_s))
    end

    def insert_rows(table, rows, replace_existing = false)
      return true if rows.empty?

      # For small number of rows, use individual inserts
      if rows.size <= 3
        rows.each { |values| insert_row(table, values, replace_existing) }
        return true
      end

      # For larger batches, use multi-row insert
      first_row = rows.first
      prepared_values = prepare_values(table, first_row)
      columns = prepared_values.keys.map(&:to_s).join(',')

      # Create the multi-row insert statement
      query = if replace_existing
                "INSERT OR REPLACE INTO #{table} (#{columns}) VALUES "
              else
                "INSERT INTO #{table} (#{columns}) VALUES "
              end

      # Build value placeholders for all rows
      placeholders = []
      all_values = []

      rows.each do |row_values|
        prepared = prepare_values(table, row_values)

        # Skip rows with mismatched columns
        next unless prepared.keys.map(&:to_s).sort == prepared_values.keys.map(&:to_s).sort

        placeholders << "(#{Array.new(prepared.size, '?').join(',')})"
        all_values.concat(prepared.values.map(&:to_s))
      end

      query << placeholders.join(',')

      execute_query(table, query, all_values)
      true
    rescue => e
      log_error(e)
      false
    end

    def setup(db_path, readonly = 0)
      @s_db = SQLite3::Database.new(db_path) unless @s_db
      return if readonly.to_i > 0

      DB_SCHEMA.each do |table_name, schema|
        create_or_update_table(table_name, schema)
        create_indices(table_name, schema) if schema[:unique]
      end
    end

    def touch_rows(table, conditions, additionals = {})
      update_rows(table, {}, conditions, additionals)
    end

    def update_rows(table, values, conditions, additionals = {})
      prepared_values = prepare_values(table, values, 1)
      set_clause = prepared_values.keys.map { |c| "#{c} = (?)" }.join(', ')

      query = "UPDATE #{table} SET #{set_clause}"
      query << prepare_conditions(conditions, additionals)

      values_for_query = prepared_values.values.map(&:to_s) +
        conditions.values.map(&:to_s) +
        additionals.values.map(&:to_s)

      execute_query(table, query, values_for_query)
    rescue => e
      log_error(e)
      nil
    end

    private

    def create_or_update_table(table_name, schema)
      replace = 0
      table_create(table_name, schema[:columns])

      table_def = table_columns(table_name)
      db_columns = table_def.keys.map(&:to_s)

      # Add missing columns
      schema[:columns].each do |column, definition|
        unless db_columns.include?(column.to_s)
          @s_db.execute("ALTER TABLE #{table_name} ADD COLUMN #{column} #{definition}")
        end

        # Check if column definition has changed
        if table_def[column] && table_def[column].downcase != definition.downcase
          replace = 1
          break
        end
      end

      # Recreate table if column definitions changed
      if replace > 0
        recreate_table(table_name, schema, db_columns)
      end
    end

    def recreate_table(table_name, schema, db_columns)
      MediaLibrarian.app.speaker.speak_up("Definition of one or more columns of table '#{table_name}' has changed, will modify the schema")

      temp_table = "tmp_#{table_name}"
      table_create(temp_table, schema[:columns])

      # Copy data from existing columns
      column_list = schema[:columns].keys.map do |column|
        db_columns.include?(column.to_s) ? column.to_s : '0'
      end.join(', ')

      @s_db.execute("INSERT OR IGNORE INTO #{temp_table} SELECT #{column_list} FROM #{table_name}")
      @s_db.execute("DROP TABLE #{table_name}")
      @s_db.execute("ALTER TABLE #{temp_table} RENAME TO #{table_name}")
    end

    def create_indices(table_name, schema)
      idx_list = index_list(table_name)
      unique_columns = schema[:unique]

      if idx_list[:unique].nil? ||
        !(unique_columns - idx_list[:unique]).empty? ||
        !(idx_list[:unique] - unique_columns).empty?

        MediaLibrarian.app.speaker.speak_up("Missing index on '#{table_name}(#{unique_columns.join(', ')})', adding index now")
        index_name = "idx_#{table_name}_#{unique_columns.join('_')}"
        columns_list = unique_columns.join(', ')
        @s_db.execute("CREATE UNIQUE INDEX #{index_name} ON #{table_name}(#{columns_list})")
      end
    end

    def execute_query(table, query, values, write = 1)
      tries ||= 3
      query_str = query.dup
      query_log = query.dup

      values.each do |value|
        query_str.sub!(/([\(,])\?([\),])/, "\\1'#{value}'\\2")
        query_log.sub!(/([\(,])\?([\),])/, "\\1'#{value.to_s[0..100]}'\\2")
      end

      if Env.pretend? && write > 0
        return MediaLibrarian.app.speaker.speak_up("Would #{query_log}")
      end

      MediaLibrarian.app.speaker.speak_up("Executing SQL query: '#{query_log}'", 0) if Env.debug?
      raise 'ReadOnly Db' if write > 0 && @readonly > 0

      Utils.lock_block("db_#{table}") do
        statement = @s_db.prepare(query)
        statement.execute(values)
      end
    rescue => e
      if (tries -= 1) >= 0
        sleep 10
        retry
      else
        log_error(e, query)
        raise e
      end
    end

    def log_error(error, query = nil)
      context = query ? { query: query } : {}
      MediaLibrarian.app.speaker.tell_error(error, Utils.arguments_dump(binding, 2, "Storage::Db", context))
    end

    def index_list(table)
      index_list = {}

      @s_db.execute("PRAGMA index_list('#{table}')").each do |idx|
        index_name = idx[1]
        index_type = idx[2].to_i > 0 && idx[3] != 'pk' ? :unique : :primary_key

        index_list[index_type] = []
        @s_db.execute("PRAGMA index_xinfo('#{index_name}')").each do |col|
          index_list[index_type] << col[2].to_sym unless col[1].to_i < 0
        end
      end

      index_list
    rescue => e
      log_error(e)
      {}
    end

    # These methods appear to be used but aren't defined in the provided code
    # Adding placeholder definitions to maintain functionality
    def prepare_conditions(conditions, additionals)
      return '' if (conditions.nil? || conditions.empty?) && (additionals.nil? || additionals.empty?)

      parts = []
      parts << conditions.map { |k, _| "#{k} = (?)" }.join(' AND ') unless conditions.nil? || conditions.empty?
      parts << additionals.map { |k, _| "#{k} (?)" }.join(' AND ') unless additionals.nil? || additionals.empty?

      " WHERE #{parts.join(' AND ')}"
    end

    def prepare_values(table, values, update_only = false)
      # Handle array inputs by converting to hash based on table schema
      if values.is_a?(Array)
        table_sym = table.to_sym
        schema = DB_SCHEMA[table_sym]

        if schema && schema[:columns]
          column_keys = schema[:columns].keys
          # Create a hash from the array using column names as keys
          values_hash = {}
          values.each_with_index do |value, index|
            values_hash[column_keys[index]] = value if index < column_keys.length
          end
          values = values_hash
        else
          # If schema not found, return the array as is
          return values
        end
      end

      result = values.dup
      table_sym = table.to_sym
      schema = DB_SCHEMA[table_sym]

      if schema && schema[:columns]
        # Add created_at timestamp for new records
        if !update_only && schema[:columns].include?(:created_at) &&
          !result.has_key?(:created_at) && !result.has_key?('created_at')
          result[:created_at] = Time.now.to_s
        end

        # Always update updated_at timestamp when column exists
        if schema[:columns].include?(:updated_at) &&
          !result.has_key?(:updated_at) && !result.has_key?('updated_at')
          result[:updated_at] = Time.now.to_s
        end
      end

      result
    rescue => e
      MediaLibrarian.app.speaker.tell_error(e, Utils.arguments_dump(binding))
      values
    end

    def table_columns(table)
      tbl_def = {}
      @s_db.execute("PRAGMA table_info('#{table}')").each do |column_info|
        id, name, type, not_null, default_value, primary_key = column_info
        tbl_def[name.to_sym] = "#{type}#{' NOT NULL' if not_null.to_i > 0}#{' PRIMARY KEY' if primary_key.to_i > 0}"
      end
      tbl_def
    rescue => e
      log_error(e)
      {}
    end

    def table_create(table_name, schema)
      column_definitions = schema.map { |column, definition| "#{column} #{definition}" }.join(', ')
      @s_db.execute("CREATE TABLE IF NOT EXISTS #{table_name} (#{column_definitions})")
    end
  end
end
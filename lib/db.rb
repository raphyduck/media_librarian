DB_SCHEMA = {
    :queues_state =>
        {
            :queue_name => 'varchar(200) primary key',
            :value => 'text',
            :created_at => 'datetime'
        },
    :metadata_search => {
        :keywords => 'text primary key',
        :type => 'integer',
        :result => 'text',
        :created_at => 'datetime'
    },
    :torrents => {
        :name => 'varchar(500) primary key',
        :identifier => 'text',
        :identifiers => 'text',
        :tattributes => 'text',
        :created_at => 'datetime',
        :updated_at => 'datetime',
        :waiting_until => 'datetime',
        :torrent_id => 'text',
        :status => 'integer'
    },
    :seen => {:category => 'varchar(200)',
              :entry => 'text primary key',
              :created_at => 'datetime'
    },
    :trakt_auth => {
        :account => 'varchar(30) primary key',
        :access_token => 'varchar(200)',
        :refresh_token => 'varchar(200)',
        :created_at => 'datetime',
        :expires_in => 'datetime'
    }
}

module Storage
  class Db
    def initialize(db_path, readonly = 0)
      setup(db_path)
      @s_db = SQLite3::Database.new db_path unless @s_db
      @readonly = readonly
    end

    def delete_rows(table, conditions = {}, additionals = {})
      q = "delete from #{table}"
      q << prepare_conditions(conditions, additionals)
      execute_query(q, conditions.map { |_, v| v } + additionals.map { |_, v| v })
    rescue => e
      $speaker.tell_error(e, "Storage::Db.new.delete_rows")
    end

    def execute(raw_sql)
      @s_db.execute(raw_sql)
    end

    def get_main_column(table)
      case table
        when 'seen'
          :entry
        when 'torrents'
          :name
        when 'metadata_search'
          :keywords
        else
          nil
      end
    end

    def get_rows(table, conditions = {}, additionals = {})
      q = "select * from #{table}"
      q << prepare_conditions(conditions, additionals)
      r = execute_query(q, conditions.map { |_, v| v } + additionals.map { |_, v| v }, 0)
      res = []
      r.each do |l|
        i = -1
        res << Hash[current_schema(table).map { |k| i+=1; [k.to_sym, l[i]] }]
      end
      res
    rescue => e
      $speaker.tell_error(e, "Storage::Db.new.get_rows")
      []
    end

    def insert_row(table, values, or_replace = 0)
      values = prepare_values(table, values)
      q = "insert#{' or replace' if or_replace.to_i > 0} into #{table} (#{values.map { |k, _| k.to_s }.join(',')}) values (#{values.map { |_, _| '?' }.join(',')})"
      execute_query(q, values.map { |_, v| v.to_s })
    end

    def insert_rows(table, rows)
      rows.each do |values|
        insert_row(table, values)
      end
    end

    def setup(db_path)
      @s_db = SQLite3::Database.new db_path unless @s_db
      DB_SCHEMA.each do |t, s|
        @s_db.execute "create table if not exists #{t} (#{s.map { |c, v| c.to_s + ' ' + v.to_s }.join(', ')})"
        s.each do |c, v|
          @s_db.execute "alter table #{t} add column #{c} #{v}" unless current_schema(t.to_s).include?(c.to_s)
        end
      end
    end

    def update_rows(table, values, conditions, additionals = {})
      values = prepare_values(table, values, 1)
      q = "update #{table} set #{values.map { |c, _| c.to_s + ' = (?)' }.join(', ')}"
      q << prepare_conditions(conditions, additionals)
      execute_query(q, values.map { |_, v| v } + conditions.map { |_, v| v } + additionals.map { |_, v| v })
    rescue => e
      $speaker.tell_error(e, "Storage::Db.new.update_rows")
    end

    private

    def current_schema(table)
      @s_db.execute("PRAGMA table_info('#{table}')").map { |c| c[1] } rescue []
    end

    def execute_query(query, values, write = 1)
      return $speaker.speak_up("Would #{query}") if Env.pretend? && write > 0
      raise 'ReadOnly Db' if write > 0 && @readonly > 0
      Utils.lock_block('db') {
        ins = @s_db.prepare(query)
        ins.execute(values)
      }
    end

    def prepare_conditions(conditions = {}, additionals = {})
      q = ''
      q << ' where ' if (conditions && !conditions.empty?) || (additionals && !additionals.empty?)
      q << conditions.map { |k, _| "#{k} = (?)" }.join(' and ') if conditions && !conditions.empty?
      q << ' and ' if conditions && !conditions.empty? && additionals && !additionals.empty?
      q << additionals.map { |k, _| "#{k} (?)" }.join(' and ') if additionals && !additionals.empty?
      q
    end

    def prepare_values(table, values, update_only = 0)
      values.merge!({:created_at => Time.now.to_s}) if DB_SCHEMA[table.to_sym].include?(:created_at) if update_only == 0
      values.merge!({:updated_at => Time.now.to_s}) if DB_SCHEMA[table.to_sym].include?(:updated_at)
      values
    end
  end

end
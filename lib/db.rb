DB_SCHEMA = {
    :queues_state => {
        :columns => {
            :queue_name => 'varchar(200) primary key',
            :value => 'text',
            :created_at => 'datetime'
        }
    },
    :metadata_search => {
        :columns => {
            :keywords => 'text',
            :type => 'integer',
            :result => 'text',
            :created_at => 'datetime'
        },
        :unique => [:keywords, :type]
    },
    :torrents => {
        :columns => {
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
        :unique => [:torrent_id]
    },
    :trakt_auth => {
        :columns => {
            :account => 'varchar(30) primary key',
            :access_token => 'varchar(200)',
            :token_type => 'varchar(200)',
            :refresh_token => 'varchar(200)',
            :scope => 'varchar(200)',
            :created_at => 'integer',
            :expires_in => 'integer'
        }
    }
}

module Storage
  class Db
    def initialize(db_path, readonly = 0)
      @s_db = SQLite3::Database.new db_path unless @s_db
      setup(db_path, readonly)
      @readonly = readonly
    end

    def delete_rows(table, conditions = {}, additionals = {})
      q = "delete from #{table}"
      q << prepare_conditions(conditions, additionals)
      execute_query(table, q, conditions.map {|_, v| v} + additionals.map {|_, v| v})
    rescue
      nil
    end

    def dump_schema
      sch = {}
      get_rows('sqlite_master', {:type => 'table'}).each do |t|
        sch[t[:name].to_sym] = table_columns(t[:name])
      end
      sch
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
      q = "select * from #{table}"
      q << prepare_conditions(conditions, additionals)
      r = execute_query(table, q, conditions.map {|_, v| v.to_s} + additionals.map {|_, v| v.to_s}, 0)
      res = []
      r.each do |l|
        i = -1
        res << Hash[table_columns(table).map {|k, _| i += 1; [k.to_sym, l[i].is_a?(String) && l[i].match(/^[{\[].*[}\]]$/) ? eval(l[i]) : l[i] ]}]
      end
      res
    rescue
      []
    end

    def insert_row(table, values, or_replace = 0)
      values = prepare_values(table, values)
      q = "insert#{' or replace' if or_replace.to_i > 0} into #{table} (#{values.map {|k, _| k.to_s}.join(',')}) values (#{values.map {|_, _| '?'}.join(',')})"
      execute_query(table, q, values.map {|_, v| v.to_s})
    end

    def insert_rows(table, rows)
      rows.each do |values|
        insert_row(table, values)
      end
    end

    def setup(db_path, readonly = 0)
      @s_db = SQLite3::Database.new db_path unless @s_db
      return if readonly.to_i > 0
      DB_SCHEMA.each do |t, s|
        replace = 0
        table_create(t, s[:columns])
        tbl_def = table_columns(t)
        db_columns = tbl_def.map {|tcn, _| tcn.to_s}
        s[:columns].each do |c, v|
          @s_db.execute "alter table #{t} add column #{c} #{v}" unless db_columns.include?(c.to_s)
          if tbl_def[c].downcase != v.downcase
            replace = 1
            break
          end
        end
        if replace > 0
          $speaker.speak_up "Definition of one or more columns of table '#{t}' has changed, will modify the schema"
          table_create("tmp_#{t}", s[:columns])
          @s_db.execute "INSERT OR IGNORE INTO tmp_#{t} SELECT #{s[:columns].map {|c, _| db_columns.include?(c.to_s) ? c.to_s : 0}.join(', ')} FROM #{t}"
          @s_db.execute "DROP TABLE #{t}"
          @s_db.execute "ALTER TABLE tmp_#{t} RENAME TO #{t}"
        end
        if s[:unique]
          idx_list = index_list(t)
          if idx_list[:unique].nil? || !(s[:unique] - idx_list[:unique]).empty? || !(idx_list[:unique] - s[:unique]).empty?
            $speaker.speak_up "Missing index on '#{t}(#{s[:unique].join(', ')})', adding index now"
            @s_db.execute "create unique index idx_#{t}_#{s[:unique].join('_')} on #{t}(#{s[:unique].join(', ')})"
          end
        end
      end
    end

    def touch_rows(table, conditions, additionals = {})
      update_rows(table, {}, conditions, additionals)
    end

    def update_rows(table, values, conditions, additionals = {})
      values = prepare_values(table, values, 1)
      q = "update #{table} set #{values.map {|c, _| c.to_s + ' = (?)'}.join(', ')}"
      q << prepare_conditions(conditions, additionals)
      execute_query(table, q, values.map {|_, v| v.to_s} + conditions.map {|_, v| v.to_s} + additionals.map {|_, v| v.to_s})
    rescue
      nil
    end

    private

    def execute_query(table, query, values, write = 1)
      tries ||= 3
      query_str = query.dup
      query_log = query.dup
      values.each do |v|
        query_str.sub!(/([\(,])\?([\),])/, '\1\'' + v.to_s + '\'\2')
        query_log.sub!(/([\(,])\?([\),])/, '\1\'' + v.to_s[0..100] + '\'\2')
      end
      return $speaker.speak_up("Would #{query_log}") if Env.pretend? && write > 0
      $speaker.speak_up("Executing SQL query: '#{query_log}'", 0) if Env.debug?
      raise 'ReadOnly Db' if write > 0 && @readonly > 0
      Utils.lock_block("db_#{table}") {
        ins = @s_db.prepare(query)
        ins.execute(values)
      }
    rescue => e
      if (tries -= 1) >= 0
        sleep 10
        retry
      else
        $speaker.tell_error(e, Utils.arguments_dump(binding, 2, "Storage::Db"))
        raise e
      end
    end

    def index_list(table)
      index_list = {}
      @s_db.execute("PRAGMA index_list('#{table}')").each do |idx|
        iname = idx[1]
        itype = idx[2].to_i > 0 && idx[3] != 'pk' ? :unique : :primary_key
        index_list[itype] = []
        @s_db.execute("PRAGMA index_xinfo('#{iname}')").each do |col|
          index_list[itype] << col[2].to_sym unless col[1].to_i < 0
        end
      end
      index_list
    rescue
      {}
    end

    def prepare_conditions(conditions = {}, additionals = {})
      q = ''
      q << ' where ' if (conditions && !conditions.empty?) || (additionals && !additionals.empty?)
      q << conditions.map {|k, _| "#{k} = (?)"}.join(' and ') if conditions && !conditions.empty?
      q << ' and ' if conditions && !conditions.empty? && additionals && !additionals.empty?
      q << additionals.map {|k, _| "#{k} (?)"}.join(' and ') if additionals && !additionals.empty?
      q
    end

    def prepare_values(table, values, update_only = 0)
      values.merge!({:created_at => Time.now.to_s}) if DB_SCHEMA[table.to_sym] && DB_SCHEMA[table.to_sym][:columns].include?(:created_at) if update_only == 0 && values[:created_at].nil? && values['created_at'].nil?
      values.merge!({:updated_at => Time.now.to_s}) if DB_SCHEMA[table.to_sym] && DB_SCHEMA[table.to_sym][:columns].include?(:updated_at) if values[:updated_at].nil? && values['updated_at'].nil?
      values
    rescue => e
      $speaker.tell_error(e, Utils.arguments_dump(binding))
      values
    end

    def table_columns(table)
      tbl_def = {}
      @s_db.execute("PRAGMA table_info('#{table}')").each do |c|
        tbl_def[c[1].to_sym] = "#{c[2]}#{' NOT NULL' if c[3].to_i > 0}#{' PRIMARY KEY' if c[5].to_i > 0}"
      end
      tbl_def
    rescue
      {}
    end

    def table_create(tname, schema)
      @s_db.execute "create table if not exists #{tname} (#{schema.map {|c, v| c.to_s + ' ' + v.to_s}.join(', ')})"
    end
  end

end
module Storage
  class Db
    def initialize(db_path)
      setup(db_path)
      @s_db = SQLite3::Database.new db_path unless @s_db
    end

    def delete_rows(table, conditions = {})
      q = "delete from #{table}"
      q += ' where ' if (conditions && !conditions.empty?)
      q += conditions.map { |k, v| "#{k} = (?)" }.join(' and ') if conditions && !conditions.empty?
      return $speaker.speak_up("Would #{q}") if $env_flags['pretend'] > 0
      ins = @s_db.prepare(q)
      ins.execute(conditions.map { |_, v| v })
    rescue => e
      $speaker.tell_error(e, "Storage::Db.new.delete_rows")
    end

    def execute(raw_sql)
      @s_db.execute(raw_sql)
    end

    def get_rows(table, conditions = {}, additionals = [])
      q = "select * from #{table}"
      q += ' where ' if (conditions && !conditions.empty?) || (additionals && !additionals.empty?)
      q += conditions.map { |k, _| "#{k} = (?)" }.join(' and ') if conditions && !conditions.empty?
      q += ' and ' if conditions && !conditions.empty? && additionals && !additionals.empty?
      q += additionals.join(' and ') if additionals && !additionals.empty?
      ins = @s_db.prepare(q)
      r = ins.execute(conditions.map { |_, v| v })
      res = []
      r.each do |l|
        i = -1
        res << Hash[current_schema(table).map { |k| i+=1; [k, l[i]] }]
      end
      res
    rescue => e
      $speaker.tell_error(e, "Storage::Db.new.get_rows")
      []
    end

    def insert_row(table, values, or_replace = 0)
      return $speaker.speak_up("Would insert#{' or replace' if or_replace.to_i > 0} into #{table} (#{values.map { |k, _| k }.join(',')}) values (#{values.map { |_, v| v.to_s[0..50] }.join(',')})") if $env_flags['pretend'] > 0
      ins = @s_db.prepare("insert#{' or replace' if or_replace.to_i > 0} into #{table} (#{values.map { |k, _| k }.join(',')}) values (#{values.map { |_, _| '?' }.join(',')})")
      ins.execute(values.map { |_, v| v.to_s })
    end

    def insert_rows(table, rows)
      rows.each do |values|
        insert_row(table, values)
      end
    end

    def db_schema
      {
          'metadata_search' => {
              'keywords' => 'text primary key',
              'type' => 'integer',
              'result' => 'text',
              'created_at' => 'datetime'
          },
          'queues_state' => {
              'queue_name' => 'varchar(200) primary key',
              'value' => 'text',
              'created_at' => 'datetime'
          },
          'trakt_auth' => {
              'account' => 'varchar(30) primary key',
              'access_token' => 'varchar(200)',
              'refresh_token' => 'varchar(200)',
              'created_at' => 'datetime',
              'expires_in' => 'datetime'
          },
          'seen' => {
              'category' => 'varchar(200)',
              'entry' => 'text',
              'created_at' => 'datetime'
          }
      }
    end

    def setup(db_path)
      @s_db = SQLite3::Database.new db_path unless @s_db
      db_schema.each do |t, s|
        @s_db.execute "create table if not exists #{t} (#{s.map { |c, v| c + ' ' + v }.join(', ')})"
        s.each do |c, v|
          @s_db.execute "alter table #{t} add column #{c} #{v}" unless current_schema(t).include?(c)
        end
      end
    end

    private

    def current_schema(table)
      @s_db.execute("PRAGMA table_info('#{table}')").map { |c| c[1] } rescue []
    end
  end

end
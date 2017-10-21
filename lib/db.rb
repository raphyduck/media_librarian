module Storage
  class Db
    def initialize(db_path)
      setup(db_path)
      @s_db = SQLite3::Database.new db_path unless @s_db
    end

    def execute(raw_sql)
      @s_db.execute(raw_sql)
    end

    def get_rows(table, conditions = '')
      r = @s_db.execute( "select * from #{table}#{' where ' + conditions.map{|k,v| "#{k} = '#{v}'"}.join(', ') if conditions && conditions != ''}" )
      i = -1
      res = []
      r.each do |l|
        res << Hash[db_schema[table].map{|k,_| i+=1; [k,l[i]]}]
      end
      res
    rescue => e
      $speaker.tell_error(e, "Storage::Db.new.get_rows")
      []
    end

    def insert_row(table, values)
      query = "insert into #{table} (#{values.map{|k,_| k}.join(',')}) values (#{values.map{|_,v| v}.join(',')})"
      @s_db.execute query
    end

    def insert_rows(table, rows)
      rows.each do |values|
        insert_row(table, values)
      end
    end

    def db_schema
      {
          'trakt_auth' => {
              'account' => 'varchar(30)',
              'access_token' => 'varchar(200)',
              'refresh_token' => 'varchar(200)',
              'created_at' => 'datetime',
              'expires_in' => 'datetime'
          },
          'series_files' => {
              'series_name' => 'varchar(200)',
              'episode_name' => 'varchar(200)',
              'episode_season' => 'integer',
              'episodes_number' => 'integer',
              'quality' => 'varchar(200)',
              'path' => 'text',
              'created_at' => 'datetime'
          },
          'movies_files' => {
              'movies_name' => 'varchar(200)',
              'movies_year' => 'varchar(200)',
              'quality' => 'varchar(200)',
              'path' => 'text',
              'created_at' => 'datetime'
          }
      }
    end

    def setup(db_path)
      @s_db = SQLite3::Database.new db_path unless @s_db
      db_schema.each do |t, s|
        @s_db.execute "create table if not exists #{t} (#{s.map{|c, v| c + ' ' + v}.join(', ')})"
      end
    end
  end
end
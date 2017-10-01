module Storage
  class Db
    def initialize(db_path)
      setup(db_path) unless File.exist?(db_path)
      @s_db = SQLite3::Database.new db_path unless @s_db
    end

    def execute(raw_sql)
      @s_db.execute(raw_sql)
    end

    def get_rows(table, conditions = '')
      @s_db.execute( "select * from #{table}#{' where ' + conditions if conditions && conditions != ''}" )
    rescue => e
      $speaker.tell_error(e, "Storage::Db.new.get_rows")
      []
    end

    def insert_row(table, values)
      query = "insert into #{table} values ("
      cpt = 1
      values.each do |v|
        query += "'#{v}'#{',' unless cpt >= values.length}"
        cpt += 1
      end
      query += ')'
      @s_db.execute query
    end

    def setup(db_path)
      @s_db = SQLite3::Database.new db_path unless @s_db
      @s_db.execute <<-SQL
          create table trakt_auth (
            account varchar(30),
            access_token varchar(200),
            refresh_token varchar(200),
            created_at datetime,
            expires_in datetime
          );
      SQL
    end
  end
end
#Set up and open app DB
db_path=$config_dir +"/librarian.db"
$db = Storage::Db.new(db_path)
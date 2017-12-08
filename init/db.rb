#Set up and open app DB
db_path=$config_dir + '/librarian.db'
$db = Storage::Db.new(db_path)
if $config['calibre_library'] && $config['calibre_library']['path'].to_s != ''
  calibre_db = $config['calibre_library']['path'] + '/metadata.db'
  $calibre = File.exist?(calibre_db) ? Storage::Db.new(calibre_db, 1) : nil
end
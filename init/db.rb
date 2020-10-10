#Set up and open app DB
db_path=$config_dir + '/librarian.db'
$db = Storage::Db.new(db_path)
if $config['calibre_library'] && $config['calibre_library']['path'].to_s != ''
  $calibre = File.exist?($config['calibre_library']['path']) ? Storage::Db.new($config['calibre_library']['path'], 1) : nil
end
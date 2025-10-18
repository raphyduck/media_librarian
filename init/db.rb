# Set up and open app DB
app = MediaLibrarian.app
db_path = File.join(app.config_dir, 'librarian.db')
app.db = Storage::Db.new(db_path)

library_config = app.config['calibre_library']
if library_config && library_config['path'].to_s != ''
  app.calibre = File.exist?(library_config['path']) ? Storage::Db.new(library_config['path'], 1) : nil
end
# start Kodi client
require_relative '../boot/librarian'

app = MediaLibrarian::Boot.application
app.kodi = nil

if app.config['kodi']
  begin
    app.kodi = 1
    Xbmc.base_uri app.config['kodi']['host']
    Xbmc.basic_auth app.config['kodi']['username'], app.config['kodi']['password']
    Xbmc.load_api!
  rescue StandardError
    app.kodi = nil
  end
end

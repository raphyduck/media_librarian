# start Kodi client
app = MediaLibrarian.app
app.kodi = nil

if app.config['kodi']
  app.kodi = 1
  Xbmc.base_uri app.config['kodi']['host']
  Xbmc.basic_auth app.config['kodi']['username'], app.config['kodi']['password']
  Xbmc.load_api!
rescue StandardError
  app.kodi = nil
end
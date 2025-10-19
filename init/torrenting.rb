require_relative '../boot/librarian'

app = MediaLibrarian::Boot.application
app.deluge_connected = nil

if app.config['deluge'] && !app.config['deluge'].empty?
  app.t_client = TorrentClient.new(app: app)
  app.remove_torrent_on_completion = app.config['deluge']['remove_on_completion']
end

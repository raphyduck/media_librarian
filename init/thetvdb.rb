# Start thetvdb client
require_relative '../boot/librarian'

app = MediaLibrarian::Boot.application
config = app.config
app.tvdb = config['tvdb'] && config['tvdb']['api_key'] ? TvdbParty::Search.new(config['tvdb']['api_key']) : nil

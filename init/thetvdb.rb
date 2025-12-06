# Start thetvdb client
require_relative '../boot/librarian'

app = MediaLibrarian::Boot.application
config = app.config
begin
  require 'tvdb_party'
rescue LoadError => e
  app.speaker.speak_up("TVDB support disabled: #{e.message}")
  app.tvdb = nil
  return
end

app.tvdb = config['tvdb'] && config['tvdb']['api_key'] ? TvdbParty::Search.new(config['tvdb']['api_key']) : nil

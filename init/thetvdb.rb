# Start thetvdb client
config = MediaLibrarian.app.config
MediaLibrarian.app.tvdb = config['tvdb'] && config['tvdb']['api_key'] ? TvdbParty::Search.new(config['tvdb']['api_key']) : nil
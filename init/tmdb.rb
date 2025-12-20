require 'themoviedb'
require_relative '../boot/librarian'
require_relative '../lib/http_debug_logger'

app = MediaLibrarian::Boot.application
Tmdb::Api.key(app.config['tmdb']['api_key']) if app.config['tmdb'] && app.config['tmdb']['api_key']

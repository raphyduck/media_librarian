require_relative '../boot/librarian'

app = MediaLibrarian::Boot.application
Tmdb::Api.key(app.config['tmdb']['api_key']) if app.config['tmdb'] && app.config['tmdb']['api_key']

require_relative '../boot/librarian'

unless ENV['MEDIA_LIBRARIAN_CLIENT_MODE'] == '1'
  # Set up and open app DB
  container = MediaLibrarian::Boot.container
  app = container.application

  # Accessing through the container eagerly materializes the shared services.
  app.db
end

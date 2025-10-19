require_relative '../boot/librarian'

# Set up and open app DB
container = MediaLibrarian::Boot.container
app = container.application

# Accessing through the container eagerly materializes the shared services.
app.db

# Set up and open app DB
app = MediaLibrarian.app

# Accessing through the container eagerly materializes the shared services.
app.db
app.calibre

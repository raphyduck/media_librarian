# CLAUDE.md

Guide for AI assistants working on the media_librarian codebase.

## Project Overview

media_librarian is a Ruby CLI/daemon application for automating video media collection management. It handles torrent searching, media metadata enrichment, file processing (transcoding, renaming), calendar tracking for upcoming releases, and exposes an HTTP control interface. This is beta software targeting Linux only.

## Tech Stack

- **Language**: Ruby 3.2.3
- **Database**: SQLite 3 via Sequel ORM (WAL mode)
- **Autoloading**: Zeitwerk
- **HTTP Server**: WEBrick (daemon control interface)
- **Key gems**: httparty, mechanize, selenium-webdriver, feedjira, concurrent-ruby, bcrypt, streamio-ffmpeg, nokogiri
- **Dependency manager**: Bundler 2.3.22
- **Custom forks**: Several gems are sourced from the `raphyduck` GitHub org (archive-zip, deluge-rpc, mediainfo, rsync, torznab-client, trakt, tvmaze, unrar, xbmc-client)

## Repository Structure

```
librarian.rb              # Main entry point
librarian                 # Executable wrapper
boot/                     # Application boot sequence
app/                      # Domain models and logic
  ├── *.rb                # Models: Calendar, Library, Movie, TvSeries, Episode, Daemon, Client, etc.
  └── media_librarian/
      └── services/       # Service layer (9 service classes)
lib/                      # Core infrastructure and utilities
  ├── media_librarian/    # Framework core (application.rb, container.rb, command_registry.rb)
  ├── storage/db.rb       # SQLite abstraction layer
  ├── db/migrations/      # 18 database migrations
  └── *.rb                # Utilities, API clients, extensions
init/                     # Initialization scripts (loaded at startup)
config/                   # Configuration examples (conf.yml.example, api.yml.example, trackers/)
scripts/                  # Utility scripts (repair_db.sh, etc.)
test/                     # Test suite (45+ test files)
  ├── support/            # Test helpers (container_helpers.rb, dependency_stubs.rb)
  ├── app/                # Model/domain tests
  ├── lib/                # Infrastructure/utility tests
  └── services/           # Service layer tests
docs/                     # Schema documentation
```

## Build & Test Commands

```bash
# Install dependencies
./install.sh                          # System deps + bundle install + interactive config
bundle install                        # Ruby gems only

# Run the full test suite
bundle exec rake test                 # Runs all test/**/*_test.rb files

# Run a single test file
bundle exec ruby -Itest test/librarian_cli_test.rb

# Run a specific test by name
bundle exec ruby -Itest test/librarian_cli_test.rb -n test_method_name

# Run the application
bundle exec ruby librarian.rb daemon start --config ~/.medialibrarian/conf.yml
bundle exec ruby librarian.rb daemon stop
bundle exec ruby librarian.rb library process_folder --type=shows --folder=/path
```

## Testing Conventions

- Framework: **Minitest** (no RSpec)
- Test files: `test/**/*_test.rb` (must end with `_test.rb`)
- Test classes inherit from `Minitest::Test`
- Sandboxed tests use `Dir.mktmpdir` for filesystem isolation
- Stubs/fakes live in `test/support/` — `FakeSpeaker`, `FakeArgsDispatch`, container helpers
- Container-based tests use `ContainerHelpers` to build test containers with dependency stubs
- No linter or formatter is configured; follow existing code style

## Code Conventions

### Naming
- Classes: `PascalCase` (e.g., `TorrentSearch`, `CalendarFeed`)
- Methods/variables: `snake_case` (e.g., `check_all_download`, `process_folder`)
- Constants: `SCREAMING_SNAKE_CASE` (e.g., `SESSION_TTL`, `UUID_REGEX`)
- Test files: mirror source path with `_test.rb` suffix

### Style
- All files start with `# frozen_string_literal: true`
- Gems loaded with `:require => false` in Gemfile (lazy-loaded at runtime)
- Minimal inline comments; code is expected to be self-documenting
- Error handling uses bare `rescue => e` with `speak_error` / `tell_error` logging
- `Utils.arguments_dump(binding)` captures error context for debugging

### Architecture Patterns
- **Dependency injection** via `AppContainerSupport` mixin — classes call `configure(app:)` to receive the app context
- **Service container**: `MediaLibrarian::Container` centralizes all service instances
- **Command routing**: `CommandRegistry` maps CLI commands to `[ClassName, method_name]` pairs; `SimpleArgsDispatch` handles parsing
- **Thread-local state**: `Thread.current` stores request context, job IDs, logging buffers
- **Module composition**: Heavy use of mixins for shared behavior across classes

### Database
- Sequel ORM with SQLite; schema managed through numbered migrations in `lib/db/migrations/`
- WAL mode for concurrent access; write lock synchronization for multi-threaded safety
- JSON serialization for complex column types
- Auto-populated `created_at`/`updated_at` timestamps
- Corruption detection with auto-repair capability (`scripts/repair_db.sh`)

### Configuration
- YAML-based: `~/.medialibrarian/conf.yml` (app config) and `~/.medialibrarian/api.yml` (HTTP/auth config)
- Tracker configs in `~/.medialibrarian/trackers/<name>.yml`
- `SimpleConfigMan` handles loading with deep merging and placeholder detection
- Config examples in `config/` directory

## CLI Commands (CommandRegistry)

```
help                              # Show available commands
daemon start|status|stop|reload   # Daemon lifecycle
library scan_file_system          # Discover local media files
library process_folder            # Process/transcode media in a folder
library fetch_media_box           # Fetch from remote media source
library create_custom_list        # Create curated media list
torrent search                    # Search torrent trackers
torrent check_all_download        # Check/manage active downloads
tracker login                     # Authenticate with tracker (supports browser login)
calendar refresh_feed             # Refresh release calendar from providers
cache_reset                       # Clear object cache
send_email                        # Push notification email
```

## Key Services

| Service | Purpose |
|---------|---------|
| `CalendarFeedService` | Hydrates calendar from OMDB/Trakt/TMDB providers |
| `TrackerQueryService` | Searches torrent trackers via Torznab |
| `TrackerLoginService` | Browser-based tracker authentication (Selenium) |
| `TorrentQueueService` | Download queue management |
| `FileSystemScanService` | Local media file discovery and cataloging |
| `RemoteSyncService` | Remote media synchronization (rsync/SSH) |
| `MediaConversionService` | FFmpeg-based transcoding |
| `ListManagementService` | Watchlist and collection curation |

## External API Integrations

- **Trakt** (`TraktAgent`): Watchlist, collection, calendar data
- **TMDB** (`themoviedb` gem): Movie/TV metadata
- **OMDB** (`OmdbApi`): Movie metadata enrichment
- **IMDb** (`ImdbApi`): Title lookups
- **Torznab**: Torrent tracker search protocol (via `torznab-client`)
- **Kodi/XBMC**: Media center integration

## Important Notes for AI Assistants

1. **Always run tests** after making changes: `bundle exec rake test`
2. **Respect the lazy-loading pattern** — don't add eager requires to the Gemfile
3. **Use the container/DI pattern** when adding new services; include `AppContainerSupport`
4. **Thread safety matters** — the daemon is multi-threaded; use `Thread.current` for request-scoped state and respect write locks for DB access
5. **Config files live outside the repo** in `~/.medialibrarian/`; never commit real credentials
6. **Mixed-language README** — some documentation sections are in French; maintain the existing language for each section when editing
7. **No CI/CD pipeline** is configured; testing is manual via `rake test`
8. **SQLite is the only supported database**; the `Storage::Db` abstraction handles all DB access
9. **Platform**: Linux only — system dependencies include ffmpeg, mediainfo, mkvmerge, MakeMKV

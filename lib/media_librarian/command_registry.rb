module MediaLibrarian
  class CommandRegistry
    def initialize(app)
      @app = app
    end

    def actions
      @actions ||= build_actions
    end

    # One-line help text keyed by full command path (e.g. 'library scan_file_system').
    # Surfaced by SimpleArgsDispatch in `help` and unknown-command output.
    def descriptions
      {
        'help' => 'Show the list of available commands',
        'reconfigure' => 'Re-run the interactive configuration',
        'daemon' => 'Manage the background daemon',
        'daemon start' => 'Start the daemon',
        'daemon status' => 'Show the daemon status and running jobs',
        'daemon stop' => 'Stop the daemon',
        'daemon reload' => 'Reload configuration without restarting',
        'daemon kill_job' => 'Cancel a running job by id',
        'daemon dump_bus_variable' => 'Dump an internal bus variable (debug)',
        'daemon dump_mem_stat' => 'Dump memory statistics (debug)',
        'library' => 'Local media library operations',
        'library scan_file_system' => 'Discover and catalog local media files',
        'library process_folder' => 'Process/transcode media in a folder',
        'library fetch_media_box' => 'Fetch media from a remote source',
        'library create_custom_list' => 'Create a curated media list',
        'library import_csv' => 'Import a CSV list into the watchlist',
        'library compare_remote_files' => 'Compare local and remote files',
        'library handle_completed_download' => 'Post-process a completed torrent (used by the client)',
        'torrent' => 'Torrent search and download management',
        'torrent search' => 'Search configured torrent trackers',
        'torrent check_all_download' => 'Check and manage active downloads',
        'torrent check_orphaned_torrent_folders' => 'Report orphaned torrent folders',
        'torrent prevent_delete' => 'Protect a torrent from automatic deletion',
        'music' => 'Music search and library organization',
        'music import_csv' => 'Search and queue one music query per CSV line',
        'music organize' => 'Organize downloaded music into Artist/Album (dry-run by default; pass --apply=1 to move exact duplicates to the trash folder)',
        'tracker' => 'Tracker authentication',
        'tracker login' => 'Authenticate with a tracker (supports browser login)',
        'calendar' => 'Release calendar operations',
        'calendar refresh_feed' => 'Refresh the release calendar from providers',
        'list_db' => 'List database rows (debug)',
        'flush_queues' => 'Flush pending torrent download queues',
        'monitor_torrent_client' => 'Check the torrent client and free space',
        'cache_reset' => 'Clear the object cache',
        'send_email' => 'Send a notification email'
      }
    end

    private

    attr_reader :app

    def build_actions
      {
        help: ['Librarian', 'help'],
        reconfigure: ['Librarian', 'reconfigure'],
        daemon: {
          start: ['Daemon', 'start'],
          status: ['Daemon', 'status', 1, 'priority'],
          stop: ['Daemon', 'stop', 1, 'priority'],
          reload: ['Daemon', 'reload', 1, 'priority'],
          dump_bus_variable: ['BusVariable', 'display_bus_variable'],
          dump_mem_stat: ['Memory', 'stat_dump'],
          kill_job: ['Daemon', 'kill', 1, 'priority']
        },
        library: {
          compare_remote_files: ['Library', 'compare_remote_files'],
          create_custom_list: ['Library', 'create_custom_list'],
          fetch_media_box: ['Library', 'fetch_media_box'],
          handle_completed_download: ['Library', 'handle_completed_download', 4, 'handle_completed_download'],
          scan_file_system: ['FileSystemScan', 'scan'],
          import_csv: ['Library', 'import_list_csv'],
          process_folder: ['Library', 'process_folder']
        },
        torrent: {
          check_all_download: ['TorrentSearch', 'check_all_download', 1, 'torrenting'],
          check_orphaned_torrent_folders: ['TorrentClient', 'check_orphaned_torrent_folders'],
          prevent_delete: ['TorrentClient', 'no_delete_torrent'],
          search: ['TorrentSearch', 'search_from_torrents']
        },
        music: {
          import_csv: ['MusicSearch', 'import_csv'],
          organize: ['MusicLibrary', 'organize']
        },
        tracker: {
          login: ['TrackerTools', 'login']
        },
        calendar: {
          refresh_feed: ['CalendarFeed', 'refresh_feed']
        },
        usage: ['Librarian', 'help'],
        list_db: ['Utils', 'list_db'],
        flush_queues: ['TorrentClient', 'flush_queues', 1, 'torrenting'],
        monitor_torrent_client: ['TorrentClient', 'monitor_torrent_client', 1, 'torrenting'],
        cache_reset: ['Cache', 'cache_reset'],
        send_email: ['Report', 'push_email']
      }
    end
  end
end

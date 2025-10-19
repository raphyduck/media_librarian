module MediaLibrarian
  class CommandRegistry
    def initialize(app)
      @app = app
    end

    def actions
      @actions ||= build_actions
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
          get_media_list_size: ['Library', 'get_media_list_size'],
          handle_completed_download: ['Library', 'handle_completed_download', 4, 'handle_completed_download', 1],
          import_csv: ['ListStore', 'import_csv'],
          process_folder: ['Library', 'process_folder']
        },
        torrent: {
          check_all_download: ['TorrentSearch', 'check_all_download', 1, 'torrenting'],
          check_orphaned_torrent_folders: ['TorrentClient', 'check_orphaned_torrent_folders'],
          prevent_delete: ['TorrentClient', 'no_delete_torrent'],
          search: ['TorrentSearch', 'search_from_torrents']
        },
        usage: ['Librarian', 'help'],
        list_db: ['Utils', 'list_db'],
        flush_queues: ['TorrentClient', 'flush_queues', 1, 'torrenting'],
        monitor_torrent_client: ['TorrentClient', 'monitor_torrent_client', 1, 'torrenting'],
        cache_reset: ['Cache', 'cache_reset'],
        send_email: ['Report', 'push_email'],
        test_childs: ['Librarian', 'test_childs', 1, 'test_childs', 1]
      }
    end
  end
end

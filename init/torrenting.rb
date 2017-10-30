$deluge_connected = nil
$deluge_options = {}
$deluge_torrents_added = []
$deluge_torrents_preadded = []
$dir_to_delete = []
$dowloaded_links = []
$pending_magnet_links = {}
$processed_torrent_id = {}
#Start torrent_client
$t_client = TorrentClient.new
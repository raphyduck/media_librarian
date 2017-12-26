$deluge_connected = nil
#Start torrent_client
$t_client = TorrentClient.new if $config['deluge'] && !$config['deluge'].empty?
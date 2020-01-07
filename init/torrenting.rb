$deluge_connected = nil
#Start torrent_client
if $config['deluge'] && !$config['deluge'].empty?
  $t_client = TorrentClient.new
  $remove_torrent_on_completion = $config['deluge']['remove_on_completion']
end
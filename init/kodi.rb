#start Kodi client
$kodi = nil
if $config['kodi']
  $kodi = 1
  Xbmc.base_uri $config['kodi']['host']
  Xbmc.basic_auth $config['kodi']['username'], $config['kodi']['password']
  Xbmc.load_api! rescue $kodi = nil # This will call JSONRPC.Introspect and create all subclasses and methods dynamically
end
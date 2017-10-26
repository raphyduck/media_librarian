#start Kodi client
if $config['kodi']
  Xbmc.base_uri $config['kodi']['host']
  Xbmc.basic_auth $config['kodi']['username'], $config['kodi']['password']
  Xbmc.load_api! rescue nil # This will call JSONRPC.Introspect and create all subclasses and methods dynamically
end
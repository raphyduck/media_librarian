#Start thetvdb client
$tvdb = $config['tvdb'] && $config['tvdb']['api_key'] ? TvdbParty::Search.new($config['tvdb']['api_key']) : nil
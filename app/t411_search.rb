class T411Search

  def self.authenticate_all
    if $config['t411'] && !T411.authenticated?
      T411.authenticate($config['t411']['username'], $config['t411']['password'])
      Speaker.speak_up("You are #{T411.authenticated? ? 'now' : 'NOT'} connected to T411")
    end
  end

  def self.search(keyword = '', limit = 50, cid = nil, interactive = 1, filter_dead = 1, move_completed = '', rename_main = '', main_only = 0)
    success = false
    if keyword.nil? || keyword.empty?
      Speaker.speak_up('Missing arguments. usage: search keyword <limit> <categorie_id>')
      return
    end
    self.authenticate_all
    return nil unless T411.authenticated?
    if cid && cid != ''
      search = T411::Torrents.search(keyword, limit: limit, cid: cid)
    else
      search = T411::Torrents.search(keyword, limit: limit)
    end
    search = JSON.load(search)
    download_id = search.empty? ? 0 : 1
    if interactive.to_i > 0
      Speaker.speak_up("Showing result for #{search['query']} (total #{search['total']})")
      i = 1
      return success if search['torrents'].nil? || search['torrents'].empty?
      search['torrents'].each do |torrent|
        next if filter_dead.to_i > 1 && torrent['seeders'].to_i == 0
        Speaker.speak_up("Index: #{i}")
        Speaker.speak_up("Name: #{torrent['name']}")
        Speaker.speak_up("Size: #{(torrent['size'].to_f / 1024 / 1024 / 1024).round(2)} GB")
        Speaker.speak_up("Seeders: #{torrent['seeders']}")
        Speaker.speak_up("Leechers: #{torrent['leechers']}")
        Speaker.speak_up("Added: #{torrent['added']}")
        Speaker.speak_up('----------------------------------------------------')
        i += 1
      end
      Speaker.speak_up('Enter the index of the torrent you want to download, or just hit Enter if you do not want to download anything: ')
      download_id = STDIN.gets.strip
    end
    if download_id.to_i > 0
      did = search['torrents'][download_id.to_i - 1]['id']
      name = search['torrents'][download_id.to_i - 1]['name']
      Speaker.speak_up("Will download torrent '#{name}'")
      T411::Torrents.download(did, $temp_dir)
      $deluge_options[did] = {
          't_name' => name,
          'move_completed' => move_completed,
          'rename_main' => rename_main,
          'main_only' => main_only
      }
      success = true
    end
    success
  rescue => e
    Speaker.tell_error(e, "T411Search.search")
  end

end
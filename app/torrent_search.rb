class TorrentSearch

  def self.authenticate_all
    if $config['t411'] && !T411.authenticated?
      T411.authenticate($config['t411']['username'], $config['t411']['password'])
      Speaker.speak_up("You are #{T411.authenticated? ? 'now' : 'NOT'} connected to T411")
    end
  end

  def self.get_cid(type, category)
    return nil if category.nil? || category == ''
    case type
      when 'extratorrent'
        {
            :movies => 4,
            :tv => 8,
            :music => 5,
            :book => 2
        }.fetch(category.to_sym, nil)
      when 't411'
        {
            :movies => 210,
            :tv => 210,
            :music => 395,
            :ebook => 404
        }.fetch(category.to_sym, nil)
      when 'thepiratebay'
        {
            :movies => 200,
            :tv => 200,
            :music => 100,
            :book => 601
        }.fetch(category.to_sym, nil)
    end
  rescue => e
    Speaker.tell_error(e, "TorrentSearch.get_cid")
  end

  def self.get_results(type, keyword, limit, category = '', filter_dead = 1)
    tries ||= 3
    get_results = {}
    cid = self.get_cid(type, category)
    case type
      when 't411'
        if cid
          get_results = T411::Torrents.search(keyword, limit: limit, cid: cid)
        else
          get_results = T411::Torrents.search(keyword, limit: limit)
        end
        get_results = JSON.load(get_results)
      when 'extratorrent'
        search = Extratorrent::Search.new(keyword, cid)
        get_results = search.links
      when 'thepiratebay'
        search = Tpb::Search.new(keyword, cid)
        get_results = search.links
    end
    if get_results['torrents']
      get_results['torrents'].select! { |t| t['seeders'].to_i != 0 } if filter_dead.to_i > 0
      get_results['torrents'].map! { |t| t['link'] = T411::Torrents.torrent_url(t['rewritename']).to_s; t} if type == 't411'
      get_results['torrents'].sort_by!{ |t| -t['seeders'].to_i }
      get_results['torrents'] = get_results['torrents'].first(limit.to_i)
    end
    get_results
  rescue => e
    Speaker.tell_error(e, "TorrentSearch.get_results")
    retry unless (tries -= 1) <= 0
  end

  def self.get_torrent_file(type, did, name = '', url = '')
    Speaker.speak_up("Will download torrent '#{name}'")
    case type
      when 't411'
        T411::Torrents.download(did.to_i, $temp_dir)
      when 'extratorrent'
        Extratorrent::Download.download(url, $temp_dir, did)
    end
    true
  rescue => e
    Speaker.tell_error(e, "TorrentSearch.get_torrent_file")
    false
  end

  def self.search(keywords:, limit: 50, category: '', no_prompt: 0, filter_dead: 1, move_completed: '', rename_main: '', main_only: 0)
    success = false
    self.authenticate_all
    begin
      keywords = eval(keywords)
    rescue Exception
      keywords = [keywords]
    end
    keywords.each do |keyword|
      success = false
      ['t411', 'extratorrent', 'thepiratebay'].each do |type|
        break if success
        next if Speaker.ask_if_needed("Search for '#{keyword}' torrent on #{type}? (y/n)", no_prompt, 'y') != 'y'
        success = self.t_search(type, keyword, limit, category, no_prompt, filter_dead, move_completed, rename_main, main_only)
      end
    end
    success
  rescue => e
    Speaker.tell_error(e, "TorrentSearch.search")
    false
  end

  def self.get_site_keywords(type, category = '')
    category && category != '' && $config[type] && $config[type]['site_specific_kw'] && $config[type]['site_specific_kw'][category] ? " #{$config[type]['site_specific_kw'][category]}" : ''
  end

  def self.t_search(type, keyword, limit = 50, category = '', no_prompt = 0, filter_dead = 1, move_completed = '', rename_main = '', main_only = 0)
    success = false
    return false if !T411.authenticated? && type == 't411'
    keyword += self.get_site_keywords(type, category)
    search = self.get_results(type, keyword, limit, category, filter_dead)
    download_id = search.empty? || search['torrents'].nil? || search['torrents'].empty? ? 0 : 1
    if no_prompt.to_i == 0
      i = 1
      if search['torrents'].nil? || search['torrents'].empty?
        Speaker.speak_up("No results for '#{search['query']}'")
        return success
      end
      Speaker.speak_up("Showing result for '#{search['query']}' on #{type} (#{search['torrents'].length} out of total #{search['total'].to_i})")
      search['torrents'].each do |torrent|
        Speaker.speak_up('---------------------------------------------------------------')
        Speaker.speak_up("Index: #{i}")
        Speaker.speak_up("Name: #{torrent['name']}")
        Speaker.speak_up("Size: #{(torrent['size'].to_f / 1024 / 1024 / 1024).round(2)} GB")
        Speaker.speak_up("Seeders: #{torrent['seeders']}")
        Speaker.speak_up("Leechers: #{torrent['leechers']}")
        Speaker.speak_up("Added: #{torrent['added']}")
        Speaker.speak_up("Link: #{torrent['link']}")
        Speaker.speak_up('---------------------------------------------------------------')
        i += 1
      end
      Speaker.speak_up('Enter the index of the torrent you want to download, or just hit Enter if you do not want to download anything: ')
      download_id = STDIN.gets.strip
    end
    if download_id.to_i > 0
      did = search['torrents'][download_id.to_i - 1]['id']
      name = search['torrents'][download_id.to_i - 1]['name']
      url = search['torrents'][download_id.to_i - 1]['link'] ? search['torrents'][download_id.to_i - 1]['link'] : ''
      magnet = search['torrents'][download_id.to_i - 1]['magnet_link']
      if (url && url != '') || type == 't411'
        success = self.get_torrent_file(type, did, name, url)
      elsif magnet && magnet != ''
        $pending_magnet_links[did] = magnet
        success = true
      end
      $deluge_options[did] = {
          't_name' => name,
          'move_completed' => move_completed,
          'rename_main' => rename_main,
          'main_only' => main_only.to_i
      } if success
    end
    success
  end

end
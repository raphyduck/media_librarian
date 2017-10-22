class TorrentSearch

  def self.authenticate_all
    if $config['t411'] && !T411.authenticated?
      T411.authenticate($config['t411']['username'], $config['t411']['password'])
      $speaker.speak_up("You are #{T411.authenticated? ? 'now' : 'NOT'} connected to T411")
    end
  rescue => e
    $speaker.tell_error(e, "TorrentSearch.authenticate_all")
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
    $speaker.tell_error(e, "TorrentSearch.get_cid")
  end

  def self.get_results(type, keyword, limit, category = '', filter_dead = 1, url = nil, sort_by = 'seeders', filter_out = [])
    tries ||= 3
    get_results = {}
    cid = self.get_cid(type, category)
    case type
      when 't411'
        if cid
          @search = T411::Torrents.search(keyword, limit: limit, cid: cid)
        else
          @search = T411::Torrents.search(keyword, limit: limit)
        end
        get_results = JSON.load(get_results)
      when 'thepiratebay'
        @search = Tpb::Search.new(keyword.gsub(/\'\w/,''), cid)
        get_results = @search.links
      when 'torrentleech'
        @search = TorrentLeech::Search.new(keyword, url)
        get_results = @search.links
      when 'yggtorrent'
        @search = Yggtorrent::Search.new(keyword, url)
        get_results = @search.links
      when 'wop'
        @search = Wop::Search.new(keyword, url)
        get_results = @search.links
    end
    if get_results['torrents']
      filter_out.each do |fout|
        get_results['torrents'].select! { |t| t[fout].to_i != 0 }
      end
      get_results['torrents'].select! { |t| t['seeders'].to_i > filter_dead.to_i } if filter_dead.to_i > 0
      get_results['torrents'].map! { |t| t['link'] = T411::Torrents.torrent_url(t['rewritename']).to_s; t } if type == 't411'
      get_results['torrents'].sort_by! { |t| -t[sort_by].to_i }
      get_results['torrents'] = get_results['torrents'].first(limit.to_i)
    end
    get_results
  rescue => e
    $speaker.tell_error(e, "TorrentSearch.get_results")
    retry unless (tries -= 1) <= 0
  end

  def self.get_torrent_file(type, did, name = '', url = '', destination_folder = $temp_dir)
    $speaker.speak_up("Will download torrent '#{name}' from #{url}")
    case type
      when 't411'
        T411::Torrents.download(did.to_i, destination_folder)
      when 'yggtorrent', 'wop', 'torrentleech'
        @search.download(url, destination_folder, did)
    end
    did
  rescue => e
    $speaker.tell_error(e, "TorrentSearch.get_torrent_file")
    nil
  end

  def self.random_pick(site:, url:, sort_by:, output: 1, destination_folder: $temp_dir)
    case site
      when 'yggtorrent', 'torrentleech'
        search = get_results(site, '', 25, 'movies', 2, url, sort_by, ['leechers'])
      else
        search = []
    end
    (1..[output.to_i,1].max).each do |i|
      download_id = search.empty? || search['torrents'].nil? || search['torrents'][i - 1].nil? ? 0 : i
      return if download_id == 0
      name = search['torrents'][download_id.to_i - 1]['name']
      url = search['torrents'][download_id.to_i - 1]['torrent_link'] ? search['torrents'][download_id.to_i - 1]['torrent_link'] : ''
      self.get_torrent_file(site, name, name, url, destination_folder) if (url && url != '') || type == 't411'
    end
  end

  def self.search(keywords:, limit: 50, category: '', no_prompt: 0, filter_dead: 1, move_completed: '', rename_main: '', main_only: 0)
    success = nil
    self.authenticate_all
    begin
      keywords = eval(keywords)
    rescue Exception
      keywords = [keywords]
    end
    keywords.each do |keyword|
      success = nil
      TORRENT_TRACKERS.map{|x| x[:name]}.each do |type|
        break if success
        next if TORRENT_TRACKERS.map{|x| x[:name]}.first != type && $speaker.ask_if_needed("Search for '#{keyword}' torrent on #{type}? (y/n)", no_prompt, 'y') != 'y'
        success = self.t_search(type, keyword, limit, category, no_prompt, filter_dead, move_completed, rename_main, main_only)
      end
    end
    success
  rescue => e
    $speaker.tell_error(e, "TorrentSearch.search")
    nil
  end

  def self.get_site_keywords(type, category = '')
    category && category != '' && $config[type] && $config[type]['site_specific_kw'] && $config[type]['site_specific_kw'][category] ? " #{$config[type]['site_specific_kw'][category]}" : ''
  end

  def self.t_search(type, keyword, limit = 50, category = '', no_prompt = 0, filter_dead = 1, move_completed = '', rename_main = '', main_only = 0)
    success = nil
    return nil if !T411.authenticated? && type == 't411'
    keyword_s = keyword + self.get_site_keywords(type, category)
    search = self.get_results(type, keyword_s, limit, category, filter_dead)
    search = self.get_results(type, keyword, limit, category, filter_dead) if search.empty? || search['torrents'].nil? || search['torrents'].empty?
    if no_prompt.to_i == 0
      i = 1
      if search['torrents'].nil? || search['torrents'].empty?
        $speaker.speak_up("No results for '#{search['query']}' on #{type}")
        return success
      end
      $speaker.speak_up("Showing result for '#{search['query']}' on #{type} (#{search['torrents'].length} out of total #{search['total'].to_i})")
      search['torrents'].each do |torrent|
        $speaker.speak_up('---------------------------------------------------------------')
        $speaker.speak_up("Index: #{i}")
        $speaker.speak_up("Name: #{torrent['name']}")
        $speaker.speak_up("Size: #{(torrent['size'].to_f / 1024 / 1024 / 1024).round(2)} GB")
        $speaker.speak_up("Seeders: #{torrent['seeders']}")
        $speaker.speak_up("Leechers: #{torrent['leechers']}")
        $speaker.speak_up("Added: #{torrent['added']}")
        $speaker.speak_up("Link: #{URI.escape(torrent['link'])}")
        $speaker.speak_up('---------------------------------------------------------------')
        i += 1
      end
    end
    download_id = $speaker.ask_if_needed('Enter the index of the torrent you want to download, or just hit Enter if you do not want to download anything: ', no_prompt, 1).to_i
    if download_id.to_i > 0
      did = (Time.now.to_f * 1000).to_i
      name = search['torrents'][download_id.to_i - 1]['name']
      url = search['torrents'][download_id.to_i - 1]['torrent_link'] ? search['torrents'][download_id.to_i - 1]['torrent_link'] : ''
      magnet = search['torrents'][download_id.to_i - 1]['magnet_link']
      if (url && url != '') || type == 't411'
        success = self.get_torrent_file(type, did, name, url)
      elsif magnet && magnet != ''
        $pending_magnet_links[did] = magnet
        success = did
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
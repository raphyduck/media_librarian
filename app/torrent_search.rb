class TorrentSearch

  def self.get_cid(type, category)
    return nil if category.nil? || category == ''
    case type
      when 'extratorrent'
        {
            :movies => 4,
            :shows => 8,
            :music => 5,
            :book => 2
        }.fetch(category.to_sym, nil)
      when 'rarbg'
        {
            :movies => '14;48;17;44;45;47;50;51;52;42;46',
            :shows => '18;41;49',
            :music => '23;25'
        }.fetch(category.to_sym, nil)
      when 'thepiratebay'
        {
            :movies => 200,
            :shows => 200,
            :music => 100,
            :book => 601
        }.fetch(category.to_sym, nil)
      when 'torrentleech'
        {
            :movies => 'Movies',
            :shows => 'TV',
            :book => 'Books'
        }.fetch(category.to_sym, nil)
    end
  rescue => e
    $speaker.tell_error(e, "TorrentSearch.get_cid")
  end

  def self.get_results(type, keyword, limit, category = '', filter_dead = 1, url = nil, sort_by = 'seeders', filter_out = [], qualities = {}, strict = 0)
    tries ||= 3
    cid = self.get_cid(type, category)
    case type
      when 'rarbg'
        @search = RarbgTracker::Search.new(Utils.clean_search(keyword), cid)
      when 'thepiratebay'
        @search = Tpb::Search.new(Utils.clean_search(keyword).gsub(/\'\w/,''), cid)
      when 'torrentleech'
        @search = TorrentLeech::Search.new(Utils.clean_search(keyword), url, cid)
      when 'yggtorrent'
        @search = Yggtorrent::Search.new(Utils.clean_search(keyword), url)
      when 'wop'
        @search = Wop::Search.new(Utils.clean_search(keyword), url)
    end
    get_results = @search.links
    if get_results['torrents']
      get_results['torrents'].select! do |t|
        t['name'].match(Regexp.new('^.{0,2}' + Utils.regexify(keyword, strict), Regexp::IGNORECASE))
      end
      filter_out.each do |fout|
        get_results['torrents'].select! { |t| t[fout].to_i != 0 }
      end
      get_results['torrents'].select! { |t| t['size'].to_f >= qualities['min_size'].to_f * 1024 * 1024 } unless qualities.nil? || qualities['min_size'].nil?
      get_results['torrents'].select! { |t| t['size'].to_f <= qualities['max_size'].to_f * 1024 * 1024 } unless qualities.nil? || qualities['max_size'].nil?
      get_results['torrents'].select! { |t| t['seeders'].to_i >= filter_dead.to_i } if filter_dead.to_i > 0
      get_results['torrents'].sort_by! { |t| -t[sort_by].to_i }
      get_results['torrents'] = get_results['torrents'].first(limit.to_i)
    end
    get_results
  rescue => e
    $speaker.tell_error(e, "TorrentSearch.get_results")
    retry unless (tries -= 1) <= 0
    {}
  end

  def self.get_torrent_file(type, did, name = '', url = '', destination_folder = $temp_dir)
    $speaker.speak_up("Will download torrent '#{name}' from #{url}")
    return did if $env_flags['pretend'] > 0
    case type
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
      self.get_torrent_file(site, name, name, url, destination_folder) if (url && url != '')
    end
  end

  def self.search(keywords:, limit: 50, category: '', no_prompt: 0, filter_dead: 1, move_completed: '', rename_main: '', main_only: 0, only_on_trackers: [], qualities: {})
    success = nil
    keywords = [keywords] if keywords.is_a?(String)
    keywords.each do |keyword|
      success = nil
      TORRENT_TRACKERS.map{|x| x[:name]}.each do |type|
        break if success
        next if !only_on_trackers.nil? && !only_on_trackers.empty? && !only_on_trackers.include?(type)
        next if TORRENT_TRACKERS.map{|x| x[:name]}.first != type && $speaker.ask_if_needed("Search for '#{keyword}' torrent on #{type}? (y/n)", no_prompt, 'y') != 'y'
        success = self.t_search(type, keyword, limit, category, no_prompt, filter_dead, move_completed, rename_main, main_only, qualities)
      end
    end
    success
  rescue => e
    $speaker.tell_error(e, "TorrentSearch.search")
    nil
  end

  def self.sort_results(results, qualities)
    MediaInfo.sort_media_files(results.map{|t|t[:file] = t['name']; t}, qualities)
  end

  def self.get_site_keywords(type, category = '')
    category && category != '' && $config[type] && $config[type]['site_specific_kw'] && $config[type]['site_specific_kw'][category] ? " #{$config[type]['site_specific_kw'][category]}" : ''
  end

  def self.t_search(type, keyword, limit = 50, category = '', no_prompt = 0, filter_dead = 1, move_completed = '', rename_main = '', main_only = 0, qualities = {})
    success = nil
    keyword_s = keyword + self.get_site_keywords(type, category)
    search = self.get_results(type, keyword_s, limit, category, filter_dead, nil, 'seeders', [], qualities, no_prompt)
    search = self.get_results(type, keyword, limit, category, filter_dead, nil, 'seeders', [], qualities, no_prompt) if keyword_s != keyword && (search.empty? || search['torrents'].nil? || search['torrents'].empty?)
    search = self.get_results(type, MediaInfo.clear_year(keyword, 1), limit, category, filter_dead, nil, 'seeders', [],  qualities, no_prompt) if keyword.gsub(/\(?\d{4}\)?/,'') != keyword&& (search.empty? || search['torrents'].nil? || search['torrents'].empty?)
    search['torrents'] = sort_results(search['torrents'], qualities) if !qualities.nil? && !qualities.empty?
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
    if download_id.to_i > 0 && search['torrents'][download_id.to_i - 1]
      did = (Time.now.to_f * 1000).to_i
      name = search['torrents'][download_id.to_i - 1]['name']
      url = search['torrents'][download_id.to_i - 1]['torrent_link'] ? search['torrents'][download_id.to_i - 1]['torrent_link'] : ''
      magnet = search['torrents'][download_id.to_i - 1]['magnet_link']
      if url.to_s != ''
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
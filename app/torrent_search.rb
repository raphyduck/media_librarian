class TorrentSearch

  def self.check_status(identifier, timeout = 10, download = nil)
    if download.nil?
      d = $db.get_rows('seen', {:category => 'download', :entry => identifier})
      return if d.empty?
      download = d.first
    end
    status = $t_client.get_torrent_status(download[:torrent_id], ['name', 'progress'])
    return if status.nil?
    progress = status['progress'].to_i
    return if progress < 100 && Date.parse(download[:created_at]) >= Date.today - timeout.to_i.days
    if progress >= 100
      Utils.entry_seen('global', identifier)
    elsif Date.parse(download[:created_at]) < Date.today - timeout.days
      $speaker.speak_up("Download #{identifier} has failed, removing it from download entries")
      Report.sent_out("Failed download - #{identifier}") if $action
      $t_client.remove_torrent(download[:torrent_id], true)
    end
    $db.delete_rows('seen', {:category => 'download', :entry => identifier})
  end

  def self.check_all_download(timeout: 10)
    $db.get_rows('seen', {:category => 'download'}).each do |d|
      check_status(d[:entry], timeout, d)
    end
  end

  def self.get_cid(type, category)
    return nil if category.nil? || category == ''
    case type
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
      when 'yggtorrent'
        {
            :movies => 'category=2145&subcategory=2183&',
            :shows => 'category=2145&subcategory=2184&',
            :music => 'category=2139&subcategory=2148&',
            :book => 'category=2140&subcategory=all&'
        }.fetch(category.to_sym, nil)
      when 'wop'
        {
            :movies => 'cats1[]=30&cats1[]=24&cats1[]=53&cats1[]=56&cats1[]=52&cats1[]=25&cats1[]=11&cats1[]=26&cats1[]=27&cats1[]=10&cats1[]=28&cats1[]=31&cats1[]=57&cats1[]=33&cats1[]=29&cats1[]=67&cats1[]=3&',
            :shows => 'cats2[]=37&cats2[]=55&cats2[]=54&cats2[]=39&cats2[]=38&cats2[]=35&cats2[]=41&cats2[]=42&cats2[]=58&cats2[]=36&cats2[]=5&',
            :music => 'cats4[]=13&cats4[]=4&cats4[]=18&cats4[]=19&'
        }.fetch(category.to_sym, nil)
    end
  end

  def self.get_results(sources:, keyword:, limit: 50, category:, qualities: {}, filter_dead: 1, url: nil, sort_by: [:tracker, :seeders], filter_out: [], strict: 0, download_criteria: {}, post_actions: {})
    tries ||= 3
    get_results = []
    r = {}
    keyword.gsub!(/[\(\)\:]/, '')
    trackers = TorrentSearch.parse_tracker_sources(sources || {})
    trackers = TORRENT_TRACKERS.map { |t, _| t } if trackers.empty?
    timeframe_trackers = TorrentSearch.parse_tracker_timeframes(sources || {})
    trackers.each do |t|
      cid = self.get_cid(t, category)
      keyword_s = keyword + self.get_site_keywords(t, category)
      case t
        when 'rarbg'
          @search = RarbgTracker::Search.new(Utils.clean_search(keyword_s), cid)
        when 'thepiratebay'
          @search = Tpb::Search.new(Utils.clean_search(keyword_s).gsub(/\'\w/, ''), cid)
        when 'torrentleech'
          @search = TorrentLeech::Search.new(Utils.clean_search(keyword_s), url, cid)
        when 'yggtorrent'
          @search = Yggtorrent::Search.new(Utils.clean_search(keyword_s), url, cid)
        when 'wop'
          @search = Wop::Search.new(Utils.clean_search(keyword_s), url)
        else
          @search = TorrentRss.new(t)
      end
      get_results += @search.links
    end
    if keyword.to_s != ''
      get_results.select! do |t|
        t[:name].match(Regexp.new('^.{0,2}' + Utils.regexify(keyword, strict), Regexp::IGNORECASE))
      end
    end
    filter_out.each do |fout|
      get_results.select! { |t| t[fout].to_i != 0 }
    end
    get_results.select! { |t| t[:seeders].to_i >= filter_dead.to_i } if filter_dead.to_i > 0
    get_results.sort_by! { |t| sort_by.map { |s| s == :tracker ? trackers.index(t[sort_by]) : -t[sort_by].to_i } }
    if !qualities.nil? && !qualities.empty?
      get_results.select! { |t| t[:size].to_f == 0 || qualities['min_size'].to_f == 0 || t[:size].to_f >= qualities['min_size'].to_f * 1024 * 1024 }
      get_results.select! { |t| t[:size].to_f == 0 || qualities['max_size'].to_f == 0 || t[:size].to_f <= qualities['max_size'].to_f * 1024 * 1024 }
    end
    unless timeframe_trackers.nil?
      get_results.map! do |t|
        t[:timeframe_tracker] = timeframe_trackers[t[:tracker]].to_s
        t
      end
    end
    get_results = get_results.first(limit.to_i) if limit.to_i > 0
    if download_criteria && !download_criteria.empty?
      download_criteria = Utils.recursive_symbolize_keys(download_criteria)
      download_criteria[:move_completed] = download_criteria[:destination][category]
      download_criteria.delete(:destination)
    end
    get_results.each do |t|
      r = Library.parse_media(
          {:type => 'torrent'}.merge(t),
          category,
          strict,
          r,
          {},
          {},
          download_criteria.merge(post_actions)
      )
    end
    r
  rescue => e
    $speaker.tell_error(e, "TorrentSearch.get_results")
    retry unless (tries -= 1) <= 0
    {}
  end

  def self.get_site_keywords(type, category = '')
    category && category != '' && $config[type] && $config[type]['site_specific_kw'] && $config[type]['site_specific_kw'][category] ? " #{$config[type]['site_specific_kw'][category]}" : ''
  end

  def self.get_torrent_file(did, name = '', url = '', destination_folder = $temp_dir)
    $speaker.speak_up("Will download torrent '#{name}' from #{url}")
    return did if Env.pretend?
    @search.download(url, destination_folder, did)
    did
  rescue => e
    $speaker.tell_error(e, "TorrentSearch.get_torrent_file")
    nil
  end

  def self.parse_tracker_sources(sources)
    case sources
      when String
        [sources]
      when Hash
        sources.map do |t, r|
          if t == 'rss'
            parse_tracker_sources(r)
          else
            t
          end
        end
      when Array
        sources.map do |s|
          parse_tracker_sources(s)
        end
    end.flatten
  end

  def self.parse_tracker_timeframes(sources, timeframe_trackers = {}, tck = '')
    if sources.is_a?(Hash)
      sources.each do |k, v|
        if k == 'timeframe' && tck.to_s != ''
          timeframe_trackers.merge!({tck => v})
        elsif v.is_a?(Hash) || v.is_a?(Array)
          timeframe_trackers = parse_tracker_timeframes(v, timeframe_trackers, k)
        end
      end
    elsif sources.is_a?(Array)
      sources.each do |s|
        timeframe_trackers = parse_tracker_timeframes(s, timeframe_trackers)
      end
    end
    timeframe_trackers
  end

  def self.processing_results(filter:, sources: {}, results: nil, no_prompt: 0, qualities: {}, limit: 50, download_criteria: {})
    torrents = []
    reload = (results.nil? || results.empty?) ? 1 : 0
    filter = filter.map { |_, a| a }.flatten if filter.is_a?(Hash)
    filter.each do |f|
      next unless f[:full_name]
      break if Library.break_processing(no_prompt)
      next if Library.skip_loop_item("Do you want to look for #{f[:type]} #{f[:full_name]} #{'(released on ' + f[:release_date].strftime('%A, %B %d, %Y') + ')' if f[:release_date]}? (y/n)", no_prompt) > 0
      $speaker.speak_up "Looking for #{f[:full_name]}" if reload > 0
      i = 1
      if reload > 0
        [f[:full_name], MediaInfo.clear_year(f[:full_name], 0)].uniq.each do |k|
          results = get_results(
              sources: sources,
              keyword: k,
              limit: limit,
              category: f[:type],
              qualities: qualities,
              filter_dead: 1,
              strict: no_prompt,
              download_criteria: download_criteria,
              post_actions: f.select { |key, _| [:files, :trakt_list, :trakt_obj, :trakt_type].include?(key) }
          )
          break unless results.nil? || results.empty?
        end
      end
      subset = MediaInfo.media_get(results, f[:identifiers])
      subset.map! { |t| t[:files] }
      subset.flatten!
      subset.select! { |t| !Utils.entry_deja_vu?('download', t[:identifiers]) }
      filtered = MediaInfo.sort_media_files(subset, qualities)
      subset = filtered unless no_prompt.to_i == 0 && filtered.empty?
      next if subset.empty?
      if no_prompt.to_i == 0
        $speaker.speak_up("Showing result for '#{f[:name]}' (#{subset.length} results)", 0)
        subset.each do |torrent|
          $speaker.speak_up('---------------------------------------------------------------')
          $speaker.speak_up("Index: #{i}")
          $speaker.speak_up("Name: #{torrent[:name]}")
          $speaker.speak_up("Size: #{(torrent[:size].to_f / 1024 / 1024 / 1024).round(2)} GB")
          $speaker.speak_up("Seeders: #{torrent[:seeders]}")
          $speaker.speak_up("Leechers: #{torrent[:leechers]}")
          $speaker.speak_up("Added: #{torrent[:added]}")
          $speaker.speak_up("Link: #{URI.escape(torrent[:link].to_s)}")
          $speaker.speak_up("Tracker: #{torrent[:tracker]}")
          $speaker.speak_up('---------------------------------------------------------------')
          i += 1
        end
      end
      download_id = $speaker.ask_if_needed('Enter the index of the torrent you want to download, or just hit Enter if you do not want to download anything: ', no_prompt, 1).to_i
      torrents << subset[download_id.to_i - 1] if subset[download_id.to_i - 1]
    end
    if no_prompt.to_i > 0
      $db.get_rows('waiting_download').each do |d|
        d[:identifiers] = eval(d[:identifiers]) rescue nil
        next unless MediaInfo.media_exist?(filter, d[:identifiers])
        if DateTime.parse(d[:waiting_until]) > DateTime.now
          $speaker.speak_up "Timeframe set for #{d[:name]}, waiting until #{d[:waiting_until]}"
          next
        end
        et = torrents.select { |t| t[:identifiers] == d[:identifiers] && t[:name] != d[:name] }
        best = MediaInfo.sort_media_files(et + [d], qualities).first
        torrents << d.merge({:tracker => 'waiting_download'}) if best[:name] == d[:name]
        torrents.select! { |t| t[:identifiers] != best[:identifiers] || t[:name] == best[:name] }
      end
    end
    torrents.each do |t|
      torrent_download(t, no_prompt)
    end
  end

  def self.search_from_torrents(torrent_sources:, filter_sources:, category:, destination: {}, no_prompt: 0, qualities: {}, download_criteria: {})
    search_list = {}
    filter_sources.each do |t, s|
      search_list.merge!(Library.process_filter_sources(source_type: t, source: s, category: category, no_prompt: no_prompt, destination: destination))
    end
    return if search_list.empty?
    results = case torrent_sources['type'].to_s
                when 'sub'
                  get_results(
                      sources: torrent_sources['trackers'],
                      keyword: '',
                      limit: 0,
                      category: category,
                      qualities: qualities,
                      strict: no_prompt,
                      download_criteria: download_criteria
                  )
                else
                  nil
              end
    processing_results(
        sources: torrent_sources['trackers'],
        filter: search_list,
        results: results,
        no_prompt: no_prompt,
        qualities: qualities,
        limit: 0,
        download_criteria: download_criteria
    )
  end

  def self.torrent_download(torrent, no_prompt = 0)
    if torrent[:tracker] != 'waiting_download' && no_prompt.to_i > 0 && (torrent[:timeframe_quality].to_s != '' || torrent[:timeframe_tracker].to_s != '')
      $db.insert_row('waiting_download', {
          :identifiers => torrent[:identifiers],
          :name => torrent[:name],
          :torrent_link => torrent[:torrent_link],
          :magnet_link => torrent[:magnet_link],
          :move_completed => torrent[:move_completed],
          :rename_main => torrent[:rename_main],
          :main_only => torrent[:main_only],
          :created_at => Time.now,
          :waiting_until => [Time.now + Utils.timeperiod_to_sec(torrent[:timeframe_quality].to_s).seconds,
                             Time.now + Utils.timeperiod_to_sec(torrent[:timeframe_tracker].to_s).seconds].max
      })
    else
      did = (Time.now.to_f * 1000).to_i
      name = torrent[:name]
      url = torrent[:torrent_link] ? torrent[:torrent_link] : ''
      magnet = torrent[:magnet_link]
      success = nil
      if url.to_s != ''
        success = self.get_torrent_file(did, name, url)
      elsif magnet && magnet != ''
        Utils.queue_state_add_or_update('pending_magnet_links', {did => magnet})
        success = did
      end
      if success.to_i > 0
        Utils.queue_state_add_or_update('deluge_options', {
            did => {
                :t_name => name,
                :move_completed => Utils.parse_filename_template(torrent[:move_completed].to_s, torrent),
                :rename_main => Utils.parse_filename_template(torrent[:rename_main].to_s, torrent),
                :main_only => torrent[:main_only].to_i,
                :entry_id => torrent[:identifiers].join
            }
        })
        if torrent[:files].is_a?(Array) && !torrent[:files].empty?
          torrent[:files].each do |f|
            Utils.queue_state_add_or_update('dir_to_delete', {f[:name] => success}) if f[:type] == 'file'
          end
        end
        TraktList.list_cache_add(torrent[:trakt_list], torrent[:trakt_type], torrent[:trakt_obj], success) if torrent[:trakt_obj]
        Utils.entry_seen('download', torrent[:identifiers])
        $db.delete_rows('waiting_download', {:identifiers => torrent[:identifiers].to_s})
      end
    end
  end

end
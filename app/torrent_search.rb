class TorrentSearch

  def self.authenticate_all(sources)
    get_trackers(sources).each do |t|
      launch_search(t, '')
    end
  end

  def self.check_status(identifier, timeout = 10, download = nil)
    if download.nil?
      d = $db.get_rows('torrents', {:status => 3, :identifiers => identifier})
      return if d.empty?
      download = d.first
    end
    progress, state = 0, ''
    $speaker.speak_up("Checking status of download #{download[:name]} (tid #{download[:torrent_id]})") if Env.debug?
    progress = -1 if download[:torrent_id].to_s == ''
    if progress >= 0
      status = $t_client.get_torrent_status(download[:torrent_id], ['name', 'progress', 'state'])
      progress = status['progress'].to_i rescue -1
      state = status['state'].to_s rescue ''
    end
    $speaker.speak_up("Progress for #{download[:name]} is #{progress}, state is #{state}, expires in #{(Time.parse(download[:updated_at]) + 30.days - Time.now).to_i/3600/24} days") if Env.debug?
    $db.touch_rows('torrents', {:name => download[:name]}) if state != 'Downloading'
    return if progress < 100 && (Time.parse(download[:updated_at]) >= Time.now - timeout.to_i.days || state != 'Downloading')
    if progress >= 100
      $db.update_rows('torrents', {:status => 4}, {:name => download[:name]})
    elsif Time.parse(download[:updated_at]) < Time.now - timeout.to_i.days
      $speaker.speak_up("Download #{identifier} has failed, removing it from download entries")
      $t_client.delete_torrent(download[:name], download[:torrent_id], progress >= 0 ? 1 : 0)
    end
  end

  def self.check_all_download(timeout: 10)
    $db.get_rows('torrents', {:status => 3}).each do |d|
      check_status(d[:identifiers], timeout, d)
    end
  end

  def self.deauth(site)
    launch_search(site, '', nil, '', 1).quit
  end

  def self.filter_results(results, condition_name, required_value, &condition)
    results.select! do |t|
      if Env.debug? && !condition.call(t)
        $speaker.speak_up "Torrent '#{t[:name]}'[#{condition_name}] do not match requirements (required #{required_value}), removing from list"
      end
      condition.call(t)
    end
  end

  def self.get_cid(type, category)
    return nil if category.nil? || category == ''
    category = 'books' if category == 'book_series'
    case type
    when 'rarbg'
      {
          :movies => [14, 48, 17, 44, 45, 47, 50, 51, 52, 42, 46],
          :shows => [18, 41, 49],
          :music => [23, 25]
      }.fetch(category.to_sym, nil)
    when 'thepiratebay'
      {
          :movies => 200,
          :shows => 200,
          :music => 100,
          :books => 601
      }.fetch(category.to_sym, nil)
    when 'torrentleech'
      {
          :movies => '8,9,11,37,43,14,12,13,41,47,15,29',
          :shows => '26,32,27',
          :books => '45,46',
          :music => '31,16'
      }.fetch(category.to_sym, nil)
    when 'yggtorrent'
      {
          :movies => 'category=2145&sub_category=2183&',
          :shows => 'category=2145&sub_category=2184&',
          :music => 'category=2139&sub_category=2148&',
          :books => 'category=2140&sub_category=all&',
          :comics => 'category=2140&sub_category=2152&'
      }.fetch(category.to_sym, nil)
    when 'wop'
      {
          :movies => 'cats1[]=30&cats1[]=24&cats1[]=53&cats1[]=56&cats1[]=52&cats1[]=25&cats1[]=11&cats1[]=26&cats1[]=27&cats1[]=10&cats1[]=28&cats1[]=31&cats1[]=57&cats1[]=33&cats1[]=29&cats1[]=67&cats1[]=3&',
          :shows => 'cats2[]=37&cats2[]=55&cats2[]=54&cats2[]=39&cats2[]=38&cats2[]=35&cats2[]=41&cats2[]=42&cats2[]=58&cats2[]=36&cats2[]=5&',
          :music => 'cats4[]=13&cats4[]=4&cats4[]=18&cats4[]=19&'
      }.fetch(category.to_sym, nil)
    end
  end

  def self.get_results(sources:, keyword:, limit: 50, category:, qualities: {}, filter_dead: 1, url: nil, sort_by: [:tracker, :seeders], filter_out: [], strict: 0, download_criteria: {}, post_actions: {}, filter_keyword: '', search_category: nil)
    tries ||= 3
    get_results = []
    r = {}
    filter_keyword = keyword.clone if filter_keyword.to_s == ''
    search_category = category if search_category.to_s == ''
    keyword.gsub!(/[\(\)\:]/, '')
    trackers = get_trackers(sources)
    timeframe_trackers = TorrentSearch.parse_tracker_timeframes(sources || {})
    trackers.each do |t|
      $speaker.speak_up("Looking for all torrents in category '#{search_category}' on '#{t}'") if keyword.to_s == '' && Env.debug?
      cid = get_cid(t, search_category)
      keyword_s = keyword + self.get_site_keywords(t, search_category)
      cr = launch_search(t, keyword_s, url, cid).links
      cr = launch_search(t, keyword, url, cid).links if cr.nil? || cr.empty?
      get_results += cr
    end
    if keyword.to_s != ''
      target_year = MediaInfo.identify_release_year(MediaInfo.detect_real_title(filter_keyword, category))
      filter_results(get_results, 'title', "to match '#{filter_keyword} (#{target_year})'") do |t|
        year = MediaInfo.identify_release_year(MediaInfo.detect_real_title(t[:name], category))
        MediaInfo.match_titles(MediaInfo.detect_real_title(t[:name], category, 1, 0),
                               filter_keyword, year, category)
      end
      get_results.map {|t| t[:formalized_name] = filter_keyword; t}
      if target_year.to_i > 0
        get_results.map {|t| t[:name].gsub!(/([\. ]\(?)(US|UK)(\)?[\. ])/, '\1' + target_year.to_s + '\3'); t}
      end
    end
    filter_out.each do |fout|
      filter_results(get_results, fout, 1) {|t| t[fout.to_sym].to_i != 0}
    end
    if filter_dead.to_i > 0
      filter_results(get_results, 'seeders', filter_dead) {|t| t[:seeders].to_i >= filter_dead.to_i}
    end
    get_results.sort_by! {|t| sort_by.map {|s| s == :tracker ? trackers.index(t[sort_by]) : -t[sort_by].to_i}}
    if !qualities.nil? && !qualities.empty?
      filter_results(get_results, 'size', "between #{qualities['min_size']}MB and #{qualities['max_size']}MB") do |t|
        f_type = TvSeries.identify_file_type(t[:name])
        (category == 'shows' && (f_type == 'season' || f_type == 'series')) ||
            ((t[:size].to_f == 0 || qualities['min_size'].to_f == 0 || t[:size].to_f >= qualities['min_size'].to_f * 1024 * 1024) &&
                (t[:size].to_f == 0 || qualities['max_size'].to_f == 0 || t[:size].to_f <= qualities['max_size'].to_f * 1024 * 1024))
      end
      if qualities['timeframe_size'].to_s != '' && (qualities['max_size'].to_s != '' || qualities['target_size'].to_s != '')
        get_results.map! do |t|
          if t[:size].to_f < (qualities['target_size'] || qualities['max_size']).to_f * 1024 * 1024
            t[:timeframe_size] = Utils.timeperiod_to_sec(qualities['timeframe_size'].to_s).to_i
          end
          t
        end
      end
    end
    unless timeframe_trackers.nil?
      get_results.map! do |t|
        t[:timeframe_tracker] = Utils.timeperiod_to_sec(timeframe_trackers[t[:tracker]].to_s).to_i
        t
      end
    end
    get_results = get_results.first(limit.to_i) if limit.to_i > 0
    if download_criteria && !download_criteria.empty?
      download_criteria = Utils.recursive_typify_keys(download_criteria)
      download_criteria[:move_completed] = download_criteria[:destination][category.to_sym] if download_criteria[:destination]
      download_criteria.delete(:destination)
      download_criteria[:whitelisted_extensions] = download_criteria[:whitelisted_extensions][MediaInfo.media_type_get(category)] rescue nil
    end
    download_criteria[:whitelisted_extensions] = FileUtils.get_valid_extensions(category) if !download_criteria[:whitelisted_extensions].is_a?(Array)
    download_criteria.merge!(post_actions)
    $speaker.speak_up "Download criteria: #{download_criteria}" if Env.debug?
    get_results.each do |t|
      _, accept = MediaInfo.filter_quality(t[:name], qualities)
      r = Library.parse_media(
          {:type => 'torrent'}.merge(t),
          category,
          strict,
          r,
          {},
          {},
          download_criteria
      ) if accept
    end
    r
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    retry unless (tries -= 1) <= 0
    {}
  end

  def self.get_site_keywords(type, category = '')
    category && category != '' && $config[type] && $config[type]['site_specific_kw'] && $config[type]['site_specific_kw'][category] ? " #{$config[type]['site_specific_kw'][category]}" : ''
  end

  def self.get_torrent_file(site, did, url = '', destination_folder = $temp_dir)
    return did if Env.pretend?
    launch_search(site, '').download(url, destination_folder, did)
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    nil
  end

  def self.get_trackers(sources)
    trackers = parse_tracker_sources(sources || {})
    trackers = TORRENT_TRACKERS.map {|t, _| t} if trackers.empty?
    trackers
  end

  def self.launch_search(site, keyword, url = nil, cid = '', quit_only = 0)
    case site
    when 'rarbg'
      RarbgTracker::Search.new(StringUtils.clean_search(keyword), cid, quit_only)
    when 'thepiratebay'
      Tpb::Search.new(StringUtils.clean_search(keyword).gsub(/\'\w/, ''), cid, quit_only)
    when 'torrentleech'
      TorrentLeech::Search.new(StringUtils.clean_search(keyword), url, cid, quit_only)
    when 'yggtorrent'
      Yggtorrent::Search.new(StringUtils.clean_search(keyword), url, cid, quit_only)
    when 'wop'
      Wop::Search.new(StringUtils.clean_search(keyword), url, cid, quit_only)
    else
      TorrentRss.new(site, quit_only)
    end
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

  def self.processing_result(results, sources, limit, f, qualities, no_prompt, download_criteria, no_waiting = 0)
    $speaker.speak_up "Processing filter '#{f[:full_name]}' (id '#{f[:identifier]}') (category '#{f[:type]}')" if Env.debug?
    f_type = f[:f_type]
    if results.nil?
      processed_search_keyword = BusVariable.new('processed_search_keyword', Vash)
      results = {}
      ks = [f[:full_name], MediaInfo.clear_year(f[:full_name], 0)]
      filter_k = f[:full_name]
      if f[:type] == 'shows' && f[:f_type] == 'episode'
        ks += [TvSeries.ep_name_to_season(f[:full_name]), MediaInfo.clear_year(TvSeries.ep_name_to_season(f[:full_name]), 0)]
      end
      f[:expect_main_file] = 1 if f[:type] == 'movies' || (f[:type] == 'shows' && f[:f_type] == 'episode')
      ks.uniq.each do |k|
        skip = false
        Utils.lock_block("#{__method__}_keywording") {
          skip = processed_search_keyword[k].to_i > 0
          processed_search_keyword[k, CACHING_TTL] = 1
        }
        next if skip
        $speaker.speak_up("Looking for keyword '#{k}'", 0)
        if ks.index(k).to_i == 2
          f[:files] += f[:existing_season_eps] if f[:files]
          filter_k = TvSeries.ep_name_to_season(f[:full_name])
          f_type = 'season'
        end
        dc = download_criteria.deep_dup
        if ks.index(k).to_i >= 2
          dc[:destination][f[:type].to_sym].gsub!(/[^\/]*{{ episode_season }}[^\/]*/, '') if dc && dc[:destination]
        end
        results = get_results(
            sources: sources,
            keyword: k.clone,
            limit: limit,
            category: f[:type],
            qualities: qualities,
            filter_dead: 2,
            strict: no_prompt,
            download_criteria: dc,
            post_actions: f.select {|key, _| ![:full_name, :identifier, :identifiers, :type, :name, :existing_season_eps].include?(key)}.deep_dup,
            filter_keyword: filter_k
        )
        break unless results.empty? #&& Cache.torrent_get(f[:identifier], f_type).empty?
      end
    end
    subset = MediaInfo.media_get(results, f[:identifiers], f_type).map {|_, t| t}
    subset.map! do |t|
      attrs = t.select {|k, _| ![:full_name, :identifier, :identifiers, :type, :name, :existing_season_eps, :files].include?(k)}.deep_dup
      t[:files].map {|ff| ff.merge(attrs)} if t[:files]
    end
    #TODO: Add all relevant files when downloading
    subset.flatten!
    subset.map! {|t| t[:files].select! {|ll| ll[:type].to_s != 'torrent'} if t[:files]; t[:files].uniq! if t[:files]; t}
    Cache.torrent_get(f[:identifier], f_type).each do |d|
      subset.select! {|tt| tt[:name] != d[:name]}
      subset << d if d[:download_now].to_i >= 0
    end
    _, qualities['min_quality'] = MediaInfo.qualities_set_minimum(f, qualities['min_quality'])
    filtered = MediaInfo.sort_media_files(subset, qualities)
    subset = filtered unless no_prompt.to_i == 0 && filtered.empty?
    if subset.empty?
      $speaker.speak_up("No torrent found for #{f[:full_name]}!", 0) if Env.debug?
      return
    end
    if no_prompt.to_i == 0 || Env.debug?
      $speaker.speak_up("Showing result for '#{f[:name]}' (#{subset.length} results)", 0)
      i = 1
      subset.each do |torrent|
        $speaker.speak_up(LINE_SEPARATOR)
        $speaker.speak_up("Index: #{i}") if no_prompt.to_i == 0
        torrent.select {|k, _| [:name, :size, :seeders, :leechers, :added, :link, :tracker, :in_db].include?(k)}.each do |k, v|
          val = case k
                when :size
                  "#{(v.to_f / 1024 / 1024 / 1024).round(2)} GB"
                when :link
                  URI.escape(v.to_s)
                else
                  v
                end
          $speaker.speak_up "#{k.to_s.titleize}: #{val}"
        end
        i += 1
      end
    end
    download_id = $speaker.ask_if_needed('Enter the index of the torrent you want to download, or just hit Enter if you do not want to download anything: ', no_prompt, 1).to_i
    return unless subset[download_id.to_i - 1]
    Utils.lock_block(__method__.to_s) {
      return if subset[download_id.to_i - 1][:in_db].to_i > 0 && subset[download_id.to_i - 1][:download_now].to_i > 2
      torrent_download(subset[download_id.to_i - 1], no_prompt, no_waiting)
    }
  end

  def self.processing_results(filter:, sources: {}, results: nil, existing_files: {}, no_prompt: 0, qualities: {}, limit: 50, download_criteria: {}, no_waiting: 0)
    filter = filter.map {|_, a| a}.flatten if filter.is_a?(Hash)
    filter = [] if filter.nil?
    filter.select! do |f|
      add = f[:full_name].to_s != '' && f[:identifier].to_s != ''
      add = !Cache.torrent_deja_vu?(f[:identifier], qualities, f[:f_type]) if add
      add
    end
    if !results.nil? && !results.empty?
      results.each do |i, ts|
        next if i.is_a?(Symbol)
        propers = ts[:files].select do |t|
          _, p = MediaInfo.identify_proper(t[:name])
          p.to_i > 0
        end
        $speaker.speak_up "Releases for '#{ts[:name]} (id '#{i}) have #{propers.count} proper torrent" if Env.debug?
        if propers.count > 0 && filter.select {|f| f[:series_name] == ts[:series_name]}.empty?
          $speaker.speak_up "Will add torrents for '#{ts[:name]}' (id '#{i}') because of proper" if Env.debug?
          ts[:files] = if existing_files[ts[:identifier]] && existing_files[ts[:identifier]][:files].is_a?(Array)
                         existing_files[ts[:identifier]][:files]
                       else
                         []
                       end
          filter << ts
        end
      end
    end
    filter.each do |f|
      break if Library.break_processing(no_prompt)
      next if Library.skip_loop_item("Do you want to look for #{f[:type]} #{f[:full_name]} #{'(released on ' + f[:release_date].strftime('%A, %B %d, %Y') + ')' if f[:release_date]}? (y/n)", no_prompt) > 0
      Librarian.route_cmd(
          ['TorrentSearch', 'processing_result', results, sources, limit, f, qualities.deep_dup, no_prompt, download_criteria, no_waiting],
          1,
          "#{Thread.current[:object]}torrent",
          6
      )
    end
  end

  def self.quit_all(sources = TORRENT_TRACKERS.keys)
    get_trackers(sources).each do |t|
      launch_search(t, '', nil, '', 1).quit
    end
  end

  def self.search_from_torrents(torrent_sources:, filter_sources:, category:, destination: {}, no_prompt: 0, qualities: {}, download_criteria: {}, search_category: nil, no_waiting: 0)
    search_list, existing_files = {}, {}
    filter_sources.each do |t, s|
      slist, elist = Library.process_filter_sources(source_type: t, source: s, category: category, no_prompt: no_prompt, destination: destination, qualities: qualities)
      search_list.merge!(slist)
      existing_files.merge!(elist)
    end
    $speaker.speak_up "Empty searchlist" if search_list.empty?
    $speaker.speak_up "No trackers source configured!" if (torrent_sources['trackers'].nil? || torrent_sources['trackers'].empty?)
    return if search_list.empty? || torrent_sources['trackers'].nil? || torrent_sources['trackers'].empty?
    authenticate_all(torrent_sources['trackers'])
    results = case torrent_sources['type'].to_s
              when 'sub'
                get_results(
                    sources: torrent_sources['trackers'],
                    keyword: '',
                    limit: 0,
                    category: category,
                    qualities: qualities,
                    strict: no_prompt,
                    download_criteria: download_criteria,
                    search_category: search_category
                )
              else
                nil
              end
    processing_results(
        sources: torrent_sources['trackers'],
        filter: search_list,
        results: results,
        existing_files: existing_files,
        no_prompt: no_prompt,
        qualities: qualities,
        limit: 0,
        download_criteria: download_criteria,
        no_waiting: no_waiting
    )
    Thread.current[:block] = lambda {quit_all(torrent_sources['trackers'])}
  end

  def self.torrent_download(torrent, no_prompt = 0, no_waiting = 0)
    waiting_until = Time.now + torrent[:timeframe_quality].to_i + torrent[:timeframe_tracker].to_i + torrent[:timeframe_size].to_i
    if no_waiting.to_i == 0 && torrent[:download_now].to_i < 2 && no_prompt.to_i > 0 && (torrent[:timeframe_quality].to_i > 0 || torrent[:timeframe_tracker].to_i > 0 || torrent[:timeframe_size].to_i > 0)
      $speaker.speak_up("Setting timeframe for '#{torrent[:name]}' on #{torrent[:tracker]} to #{waiting_until}", 0) if torrent[:in_db].to_i == 0
      torrent[:download_now] = 1
    else
      $speaker.speak_up("Adding torrent #{torrent[:name]} on #{torrent[:tracker]} to the torrents to download")
      $db.delete_rows('torrents', {}, {'name != ' => torrent[:name], 'identifier = ' => torrent[:identifier]}) unless torrent[:identifier].to_s[0..6].downcase.include?('book') #TODO: Find better way to handle books
      torrent[:download_now] = 2
    end
    if torrent[:in_db]
      $db.update_rows('torrents', {:status => torrent[:download_now]}, {:name => torrent[:name]})
    else
      $db.insert_row('torrents', {
          :identifier => torrent[:identifier],
          :identifiers => torrent[:identifiers],
          :name => torrent[:name],
          :tattributes => Cache.object_pack(torrent),
          :waiting_until => waiting_until,
          :status => torrent[:download_now]
      })
    end
  end

end
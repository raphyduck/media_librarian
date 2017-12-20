class TorrentSearch

  @processed_search_keyword = []
  @search = {}

  def self.authenticate_all(sources)
    get_trackers(sources).each do |t|
      s = launch_search(t, '')
      s.pre_auth
    end
  end

  def self.check_status(identifier, timeout = 10, download = nil)
    if download.nil?
      d = $db.get_rows('torrents', {:status => 3, :identifiers => identifier})
      return if d.empty?
      download = d.first
    end
    progress = 0
    $speaker.speak_up("Checking status of download #{download[:name]} (tid #{download[:torrent_id]})", 0)
    progress = -1 if download[:torrent_id].to_s == '' && Time.parse(download[:updated_at]) < Time.now - 1.hour
    if progress >= 0
      status = $t_client.get_torrent_status(download[:torrent_id], ['name', 'progress'])
      progress = status['progress'].to_i rescue 0
    end
    $speaker.speak_up("Progress for #{download[:name]} is #{progress}", 0)
    return if (progress >= 0 && progress < 100) && Time.parse(download[:updated_at]) >= Time.now - timeout.to_i.days
    if progress >= 100
      $db.update_rows('torrents', {:status => 4}, {:name => download[:name]})
      Cache.entry_seen('global', identifier)
    elsif Time.parse(download[:updated_at]) < Time.now - timeout.to_i.days
      $speaker.speak_up("Download #{identifier} has failed, removing it from download entries")
      $t_client.remove_torrent(download[:torrent_id], true) if progress >= 0
    end
    $db.delete_rows('seen', {:category => 'download', :entry => identifier})
  end

  def self.check_all_download(timeout: 10)
    $db.get_rows('torrents', {:status => 3}).each do |d|
      check_status(d[:identifiers], timeout, d)
    end
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
    category = 'book' if category == 'book_series'
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
            :books => 601
        }.fetch(category.to_sym, nil)
      when 'torrentleech'
        {
            :movies => 'Movies',
            :shows => 'TV',
            :books => 'Book'
        }.fetch(category.to_sym, nil)
      when 'yggtorrent'
        {
            :movies => 'category=2145&subcategory=2183&',
            :shows => 'category=2145&subcategory=2184&',
            :music => 'category=2139&subcategory=2148&',
            :books => 'category=2140&subcategory=all&'
        }.fetch(category.to_sym, nil)
      when 'wop'
        {
            :movies => 'cats1[]=30&cats1[]=24&cats1[]=53&cats1[]=56&cats1[]=52&cats1[]=25&cats1[]=11&cats1[]=26&cats1[]=27&cats1[]=10&cats1[]=28&cats1[]=31&cats1[]=57&cats1[]=33&cats1[]=29&cats1[]=67&cats1[]=3&',
            :shows => 'cats2[]=37&cats2[]=55&cats2[]=54&cats2[]=39&cats2[]=38&cats2[]=35&cats2[]=41&cats2[]=42&cats2[]=58&cats2[]=36&cats2[]=5&',
            :music => 'cats4[]=13&cats4[]=4&cats4[]=18&cats4[]=19&'
        }.fetch(category.to_sym, nil)
    end
  end

  def self.get_results(sources:, keyword:, limit: 50, category:, qualities: {}, filter_dead: 1, url: nil, sort_by: [:tracker, :seeders], filter_out: [], strict: 0, download_criteria: {}, post_actions: {}, filter_keyword: '')
    tries ||= 3
    get_results = []
    r = {}
    filter_keyword = keyword.clone if filter_keyword.to_s == ''
    keyword.gsub!(/[\(\)\:]/, '')
    trackers = get_trackers(sources)
    timeframe_trackers = TorrentSearch.parse_tracker_timeframes(sources || {})
    trackers.each do |t|
      cid = self.get_cid(t, category)
      keyword_s = keyword + self.get_site_keywords(t, category)
      s = launch_search(t, keyword_s, url, cid)
      get_results += s.links
    end
    if keyword.to_s != ''
      target_year = MediaInfo.identify_release_year(MediaInfo.detect_real_title(filter_keyword, category))
      filter_results(get_results, 'title', "to match '#{filter_keyword} (#{target_year})'") do |t|
        year = MediaInfo.identify_release_year(MediaInfo.detect_real_title(t[:name], category))
        MediaInfo.match_titles(MediaInfo.detect_real_title(t[:name], category, 1, 0),
                               filter_keyword, year, category)
      end
      get_results.map { |t| t[:formalized_name] = filter_keyword; t }
      if target_year.to_i > 0
        get_results.map { |t| t[:name].gsub!(/([\. ]\(?)(US|UK)(\)?[\. ])/, '\1' + target_year.to_s + '\3'); t }
      end
    end
    filter_out.each do |fout|
      filter_results(get_results, fout, 1) { |t| t[fout.to_sym].to_i != 0 }
    end
    if filter_dead.to_i > 0
      filter_results(get_results, 'seeders', filter_dead) { |t| t[:seeders].to_i >= filter_dead.to_i }
    end
    get_results.sort_by! { |t| sort_by.map { |s| s == :tracker ? trackers.index(t[sort_by]) : -t[sort_by].to_i } }
    if !qualities.nil? && !qualities.empty?
      filter_results(get_results, 'size', "between #{qualities['min_size']}MN and #{qualities['max_size']}MB") do |t|
        f_type = TvSeries.identify_file_type(t[:name])
        f_type == 'season' || f_type == 'series' ||
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
      download_criteria = Utils.recursive_symbolize_keys(download_criteria)
      download_criteria[:move_completed] = download_criteria[:destination][category.to_sym] if download_criteria[:destination]
      download_criteria.delete(:destination)
    end
    download_criteria.merge!(post_actions)
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
    $speaker.tell_error(e, "TorrentSearch.get_results")
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
    $speaker.tell_error(e, "TorrentSearch.get_torrent_file")
    nil
  end

  def self.get_trackers(sources)
    trackers = parse_tracker_sources(sources || {})
    trackers = TORRENT_TRACKERS.map { |t, _| t } if trackers.empty?
    trackers
  end

  def self.launch_search(site, keyword, url = nil, cid = '')
    return @search[site] if @search[site] && keyword.to_s == '' && url.nil?
    case site
      when 'rarbg'
        @search[site] = RarbgTracker::Search.new(StringUtils.clean_search(keyword), cid)
      when 'thepiratebay'
        @search[site] = Tpb::Search.new(StringUtils.clean_search(keyword).gsub(/\'\w/, ''), cid)
      when 'torrentleech'
        @search[site] = TorrentLeech::Search.new(StringUtils.clean_search(keyword), url, cid)
      when 'yggtorrent'
        @search[site] = Yggtorrent::Search.new(StringUtils.clean_search(keyword), url, cid)
      when 'wop'
        @search[site] = Wop::Search.new(StringUtils.clean_search(keyword), url)
      else
        @search[site] = TorrentRss.new(site)
    end
    @search[site]
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

  def self.processing_result(results, sources, limit, f, qualities, no_prompt, download_criteria, waiting_downloads)
    $speaker.speak_up "Processing filter '#{f[:full_name]}' (id '#{f[:identifier]}')" if Env.debug?
    if results.nil?
      ks = [f[:full_name], MediaInfo.clear_year(f[:full_name], 0)]
      filter_k = f[:full_name]
      if f[:type] == 'shows' && f[:f_type] == 'episode'
        ks += [TvSeries.ep_name_to_season(f[:full_name]), MediaInfo.clear_year(TvSeries.ep_name_to_season(f[:full_name]), 0)]
      end
      ks.uniq.each do |k|
        skip = false
        Utils.lock_block("#{__method__}keywording") {
          skip = @processed_search_keyword.include?(k)
          @processed_search_keyword << k
        }
        next if skip
        $speaker.speak_up("Looking for keyword '#{k}'", 0)
        if ks.index(k).to_i == 2
          f[:files] += f[:existing_season_eps]
          filter_k = TvSeries.ep_name_to_season(f[:full_name])
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
            filter_dead: 1,
            strict: no_prompt,
            download_criteria: dc,
            post_actions: f.select { |key, _| ![:full_name, :identifier, :identifiers, :type, :name, :existing_season_eps].include?(key) }.deep_dup,
            filter_keyword: filter_k
        )
        break unless results.empty?
      end
    end
    subset = MediaInfo.media_get(results, f[:identifiers], f[:f_type]).map { |_, t| t }
    subset.map! do |t|
      attrs = t.select { |k, _| ![:full_name, :identifier, :identifiers, :type, :name, :existing_season_eps].include?(k) }.deep_dup
      t[:files].map { |ff| ff.merge(attrs) }
    end
    subset.flatten!
    subset.map { |t| t[:files].select! { |ll| ll[:type].to_s != 'torrent' }; t[:files].uniq!; t }
    subset.select! { |t| !Cache.entry_deja_vu?('download', t[:identifiers]) }
    waiting_downloads.each do |d|
      next unless d[:identifier].to_s.include?(f[:identifier].to_s)
      d[:tattributes] = Cache.object_unpack(d[:tattributes])
      if Time.parse(d[:waiting_until]) < Time.now - 365.days
        $db.delete_rows('torrents', {:name => d[:name], :identifier => d[:identifier]})
        next
      end
      next unless (f[:f_type].nil? || d[:tattributes][:f_type].nil? || d[:tattributes][:f_type].to_s == f[:f_type].to_s)
      if Time.parse(d[:waiting_until]) > Time.now
        $speaker.speak_up("Timeframe set for #{d[:name]}, waiting until #{d[:waiting_until]}", 0)
        t = 1
      else
        t = 2
      end
      subset.select! { |tt| tt[:name] != d[:name] }
      subset << d[:tattributes].merge({:download_now => t, :in_db => 1})
    end
    filtered = MediaInfo.sort_media_files(subset, qualities)
    subset = filtered unless no_prompt.to_i == 0 && filtered.empty?
    return if subset.empty?
    if no_prompt.to_i == 0 || Env.debug?
      $speaker.speak_up("Showing result for '#{f[:name]}' (#{subset.length} results)", 0)
      i = 1
      subset.each do |torrent|
        $speaker.speak_up(LINE_SEPARATOR)
        $speaker.speak_up("Index: #{i}") if no_prompt.to_i == 0
        $speaker.speak_up("Name: #{torrent[:name]}")
        $speaker.speak_up "torrent[:files] #{torrent[:files]}" if f[:type] == 'movies' #REMOVEME
        if no_prompt.to_i == 0
          $speaker.speak_up("Size: #{(torrent[:size].to_f / 1024 / 1024 / 1024).round(2)} GB")
          $speaker.speak_up("Seeders: #{torrent[:seeders]}")
          $speaker.speak_up("Leechers: #{torrent[:leechers]}")
          $speaker.speak_up("Added: #{torrent[:added]}")
          $speaker.speak_up("Link: #{URI.escape(torrent[:link].to_s)}")
        end
        $speaker.speak_up("Tracker: #{torrent[:tracker]}")
        $speaker.speak_up("Already  in DB") if torrent[:in_db].to_i > 0 && Env.debug?
        i += 1
      end
    end
    download_id = $speaker.ask_if_needed('Enter the index of the torrent you want to download, or just hit Enter if you do not want to download anything: ', no_prompt, 1).to_i
    return unless subset[download_id.to_i - 1]
    Utils.lock_block(__method__.to_s) {
      return if Cache.entry_deja_vu?('download', subset[download_id.to_i - 1][:identifiers])
      torrent_download(subset[download_id.to_i - 1], no_prompt)
    }
  end

  def self.processing_results(filter:, sources: {}, results: nil, no_prompt: 0, qualities: {}, limit: 50, download_criteria: {})
    waiting_downloads = $db.get_rows('torrents', {}, {'status < ' => 3})
    filter = filter.map { |_, a| a }.flatten if filter.is_a?(Hash)
    authenticate_all(sources) if results.nil? || results.empty?
    filter.each do |f|
      next unless f[:full_name]
      next if Cache.entry_deja_vu?('download', f[:identifiers])
      break if Library.break_processing(no_prompt)
      next if Library.skip_loop_item("Do you want to look for #{f[:type]} #{f[:full_name]} #{'(released on ' + f[:release_date].strftime('%A, %B %d, %Y') + ')' if f[:release_date]}? (y/n)", no_prompt) > 0
      Librarian.route_cmd(
          ['TorrentSearch', 'processing_result', results, sources, limit, f, qualities, no_prompt, download_criteria, waiting_downloads],
          1,
          'torrent'
      )
    end
  end

  def self.search_from_torrents(torrent_sources:, filter_sources:, category:, destination: {}, no_prompt: 0, qualities: {}, download_criteria: {})
    search_list = {}
    filter_sources.each do |t, s|
      search_list.merge!(Library.process_filter_sources(source_type: t, source: s, category: category, no_prompt: no_prompt, destination: destination))
    end
    return if search_list.empty? || torrent_sources['trackers'].nil? || torrent_sources['trackers'].empty?
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
    $db.delete_rows('torrents', {}, {'name != ' => torrent[:name], 'identifier = ' => torrent[:identifier]})
    waiting_until = Time.now + torrent[:timeframe_quality].to_i + torrent[:timeframe_tracker].to_i + torrent[:timeframe_size].to_i
    if torrent[:download_now].to_i < 2 && no_prompt.to_i > 0 && (torrent[:timeframe_quality].to_i > 0 || torrent[:timeframe_tracker].to_i > 0 || torrent[:timeframe_size].to_i > 0)
      $speaker.speak_up("Setting timeframe for #{torrent[:name]} on #{torrent[:tracker]} to #{waiting_until}", 0) if torrent[:in_db].to_i == 0
      torrent[:download_now] = 1
    else
      $speaker.speak_up("Adding torrent #{torrent[:name]} on #{torrent[:tracker]} to the torrents to download")
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
require 'uri'
class TorrentSearch
  include MediaLibrarian::AppContainerSupport

  def self.check_status(identifier, timeout = 10, download = nil)
    download = app.db.get_rows('torrents', {:status => 3, :identifiers => identifier}).first if download.nil?
    return if download.nil?
    progress, state = 0, ''
    app.speaker.speak_up("Checking status of download #{download[:name]} (tid #{download[:torrent_id]})") if Env.debug?
    progress = -1 if download[:torrent_id].to_s == ''
    if progress >= 0
      status = app.t_client.get_torrent_status(download[:torrent_id], ['name', 'progress', 'state'])
      progress = status['progress'].to_i rescue -1
      state = status.empty? ? 'none' : status['state'].to_s rescue ''
    end
    app.speaker.speak_up("Progress for #{download[:name]} is #{progress}, state is #{state}, expires in #{(Time.parse(download[:updated_at]) + 30.days - Time.now).to_i / 3600 / 24} days") if Env.debug?
    app.db.touch_rows('torrents', {:name => download[:name]}) unless ['Downloading', 'none', ''].include?(state)
    return if progress < 100 && (Time.parse(download[:updated_at]) >= Time.now - timeout.to_i.days && state != 'none' || !['Downloading', 'none', ''].include?(state))
    if progress >= 100
      app.db.update_rows('torrents', {:status => 4}, {:name => download[:name]})
    elsif Time.parse(download[:updated_at]) < Time.now - timeout.to_i.days
      app.speaker.speak_up("Download #{download[:name]} (tid '#{download[:torrent_id]}') has failed, removing it from download entries")
      app.t_client.delete_torrent(download[:name], download[:torrent_id], progress >= 0 ? 1 : 0)
    elsif state == 'none'
      app.speaker.speak_up("Download #{identifier} no longer exists, removing it from download entries")
      app.t_client.delete_torrent(download[:name], '', 1)
    end
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding))
  end

  def self.check_all_download(timeout: 10)
    app.db.get_rows('torrents', {:status => 3}).each do |d|
      check_status(d[:identifiers], timeout, d)
    end
  end

  def self.download_now?(waiting_until)
    if Time.parse(waiting_until.to_s) > Time.now
      1
    else
      2
    end
  end

  def self.filter_results(results, condition_name, required_value, &condition)
    results.select! do |t|
      if Env.debug? && !condition.call(t)
        app.speaker.speak_up "Torrent '#{t[:name]}'[#{condition_name}] do not match requirements (required #{required_value}), removing from list"
      end
      condition.call(t)
    end
  end

  def self.get_results(sources:, keyword:, limit: 50, category:, qualities: {}, filter_dead: 1, url: nil, sort_by: [:tracker, :seeders], filter_out: [], strict: 0, download_criteria: {}, post_actions: {}, search_category: nil)
    tries ||= 3
    get_results = []
    r = {}
    search_category = category if search_category.to_s == ''
    keyword.gsub!(/[\(\)\:]/, '')
    trackers = get_trackers(sources)
    timeframe_trackers = TorrentSearch.parse_tracker_timeframes(sources || {})
    trackers.each do |t|
      app.speaker.speak_up("Looking for all torrents in category '#{search_category}' on '#{t}'") if keyword.to_s == '' && Env.debug?
      keyword_s = (keyword + self.get_site_keywords(t, search_category)).strip
      cr = launch_search(t, search_category, keyword_s)
      cr = launch_search(t, search_category, keyword) if keyword_s != keyword && (cr.nil? || cr.empty?)
      get_results += cr
    end
    filter_out.each do |fout|
      filter_results(get_results, fout, 1) { |t| t[fout.to_sym].to_i != 0 }
    end
    if filter_dead.to_i > 0
      filter_results(get_results, 'seeders', filter_dead) { |t| t[:seeders].to_i >= filter_dead.to_i }
    end
    get_results.sort_by! { |t| sort_by.map { |s| s == :tracker ? trackers.index(t[sort_by]) : -t[sort_by].to_i } }
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
      download_criteria[:whitelisted_extensions] = download_criteria[:whitelisted_extensions][Metadata.media_type_get(category)] rescue nil
    end
    download_criteria[:whitelisted_extensions] = FileUtils.get_valid_extensions(category) unless download_criteria[:whitelisted_extensions].is_a?(Array)
    download_criteria.merge!(post_actions)
    get_results.each do |t|
      t[:assume_quality] = get_tracker_config(t[:tracker])['assume_quality'].to_s + ' ' + qualities['assume_quality'].to_s
      _, accept = Quality.filter_quality(t[:name], qualities, post_actions[:language], t[:assume_quality], category)
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
    app.speaker.tell_error(e, Utils.arguments_dump(binding))
    retry unless (tries -= 1) <= 0
    {}
  end

  def self.get_site_keywords(type, category = '')
    category && category != '' && app.config[type] && app.config[type]['site_specific_kw'] && app.config[type]['site_specific_kw'][category] ? " #{app.config[type]['site_specific_kw'][category]}" : ''
  end

  def self.get_torrent_file(did, url, destination_folder = app.temp_dir)
    return did if Env.pretend?
    path = "#{destination_folder}/#{did}.torrent"
    FileUtils.rm(path) if File.exist?(path)
    url = @base_url + '/' + url if url.start_with?('/')
    begin
      tries ||= 3
      app.mechanizer.get(url).save(path)
    rescue => e
      if (tries -= 1) >= 0
        sleep 1
        retry
      else
        raise e
      end
    end
    path
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding))
    nil
  end

  def self.get_trackers(sources)
    trackers = parse_tracker_sources(sources || [])
    trackers = app.trackers.map { |t, _| t } if trackers.empty?
    trackers
  end

  def self.get_tracker_config(tracker, app: self.app)
    app.trackers[tracker].config
  rescue
    {}
  end

  def self.launch_search(tracker, search_category, keyword)
    if app.trackers[tracker]
      app.trackers[tracker].search(search_category, keyword)
    else
      TorrentRss.links(tracker)
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

  def self.processing_result(results, sources, limit, f, qualities, no_prompt, download_criteria, no_waiting = 0, grab_all = 0, search_category = nil)
    app.speaker.speak_up "TorrentSearch.processing_result(results, sources, #{limit}, #{f.select { |k, _| ![:files].include?(k) }}, '#{qualities}', #{no_prompt}, '#{download_criteria}', #{no_waiting})" if Env.debug?
    f_type, extra_files = f[:f_type] || '', []
    if results.nil?
      processed_search_keyword = BusVariable.new('processed_search_keyword', Vash)
      results, ks = {}, {}
      (f[:titles] || [f[:full_name]]).each do |fn|
        ks[f_type] = [] unless ks[f_type]
        ks[f_type] << {:s => Metadata.detect_real_title(fn, f[:type], 0, 0)}
      end
      if f[:type] == 'shows' && f[:f_type] == 'episode'
        ks['season'] = [{:s => Metadata.detect_real_title(TvSeries.ep_name_to_season(f[:full_name]), f[:type], 1, 0), :extra_files => f[:existing_season_eps]},
                        {:s => Metadata.detect_real_title(TvSeries.ep_name_to_season(f[:full_name]), f[:type], 1, 1), :extra_files => f[:existing_season_eps]}]
      end
      (['series', 'season'] + ks.keys).uniq.each do |ft|
        next unless ks[ft]
        expect_main_file = f[:type] == 'movies' || (f[:type] == 'shows' && ft == 'episode') ? 1 : 0
        ks[ft].uniq.each do |k|
          skip = false
          Utils.lock_block("#{__method__}_keywording") {
            skip = processed_search_keyword[k].to_i > 0
            processed_search_keyword[k, 600] = 1
          }
          next if skip
          f_type = ft
          app.speaker.speak_up("Looking for keyword '#{k[:s]}', type '#{f[:type]}', subtype '#{f_type}'", 0)
          extra_files = k[:extra_files] || []
          dc = download_criteria.deep_dup
          dc[:destination][f[:type].to_sym].gsub!(/[^\/]*{{ episode_season }}[^\/]*/, '') if dc && dc[:destination] if f[:type] == 'shows' && f[:f_type] == 'episode' && f_type == 'season'
          results += get_results(
              sources: sources,
              keyword: k[:s].clone,
              limit: limit,
              category: f[:type],
              qualities: qualities,
              filter_dead: 2,
              strict: no_prompt,
              download_criteria: dc,
              post_actions: f.select { |key, _| ![:full_name, :identifier, :identifiers, :type, :name, :existing_season_eps].include?(key) }.deep_dup + {:expect_main_file => expect_main_file},
              search_category: search_category
          )
        end
        break unless results.empty? #&& Cache.torrent_get(f[:identifier], f_type).empty?
      end
    end
    subset = Metadata.media_get(results, f[:identifiers], f_type).map { |_, t| t }
    subset.map! do |t|
      attrs = t.select { |k, _| ![:full_name, :identifier, :identifiers, :type, :name, :existing_season_eps, :files].include?(k) }.deep_dup
      t[:files] = [] if t[:files].nil?
      t[:files] += extra_files
      t[:files].map { |ff| ff.merge(attrs) }
    end
    subset.flatten!
    subset.map! { |t| t[:files].select! { |ll| ll[:type].to_s != 'torrent' } if t[:files]; t[:files].uniq! if t[:files]; t }
    existing_torrents = []
    Cache.torrent_get(f[:identifier], f_type).each do |d|
      subset.select! { |tt| tt[:name] != d[:name] }
      subset << d if d[:download_now].to_i >= 0
      existing_torrents << d if d[:download_now].to_i >= 3
    end
    ef, qualities['min_quality'] = Quality.qualities_set_minimum(f, qualities['min_quality'], (f[:season_incomplete] || {})[f[:episode_season].to_i])
    qualities['strict'] = qualities['strict'].to_i > 0 || ef != '' ? 1 : 0
    filtered = Quality.sort_media_files(subset, qualities, f[:language], f[:type])
    subset = filtered unless no_prompt.to_i == 0 && filtered.empty?
    if subset.empty?
      app.speaker.speak_up("No torrent found for #{f[:full_name]}!", 0) if Env.debug?
      return
    end
    i = 1
    subset.each do |torrent|
      break unless (grab_all.to_i > 0 && i < 6) || no_prompt.to_i == 0 || i == 1
      if no_prompt.to_i == 0 || Env.debug?
        app.speaker.speak_up("Showing result for '#{f[:name]}' (#{subset.length} results)", 0)
        app.speaker.speak_up(LINE_SEPARATOR)
        app.speaker.speak_up("Index: #{i}") if no_prompt.to_i == 0
        torrent.select { |k, _| [:name, :size, :seeders, :leechers, :added, :link, :tracker, :in_db].include?(k) }.each do |k, v|
          val = case k
                when :size
                  "#{(v.to_f / 1024 / 1024 / 1024).round(2)} GB"
                when :link
                  # URI.escape was removed in Ruby 3; use URI.encode_www_form_component instead.
                  URI.encode_www_form_component(v.to_s)
                else
                  v
                end
          app.speaker.speak_up "#{k.to_s.titleize}: #{val}"
        end
      end
      download_id = app.speaker.ask_if_needed('Enter the index of the torrent you want to download, or just hit Enter if you do not want to download anything: ', no_prompt, i).to_i
      i += 1
      next unless subset[download_id.to_i - 1]
      Utils.lock_block(__method__.to_s) {
        next if subset[download_id.to_i - 1][:in_db].to_i > 0 && subset[download_id.to_i - 1][:download_now].to_i > 2
        torrent_download(subset[download_id.to_i - 1], no_prompt, no_waiting, existing_torrents.select { |t| t[:in_db].to_i > 0 }.map { |t| t[:name] }, f[:type])
      }
    end
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding))
  end

  def self.processing_results(filter:, sources: {}, results: nil, existing_files: {}, no_prompt: 0, qualities: {}, limit: 50, download_criteria: {}, no_waiting: 0, grab_all: 0, search_category: nil)
    filter = filter.map { |_, a| a }.flatten if filter.is_a?(Hash)
    filter = [] if filter.nil?
    filter.select! do |f|
      add = f[:full_name].to_s != '' && f[:identifier].to_s != ''
      add = !Cache.torrent_deja_vu?(f[:identifier], qualities, f[:f_type], f[:language], f[:type]) if add
      add
    end
    if !results.nil? && !results.empty?
      results.each do |i, ts|
        next if i.is_a?(Symbol)
        propers = ts[:files].select do |t|
          _, p = Quality.identify_proper(t[:name])
          p.to_i > 0
        end
        app.speaker.speak_up "Releases for '#{ts[:name]} (id '#{i}) have #{propers.count} proper torrent" if Env.debug?
        if propers.count > 0 && filter.select { |f| f[:series_name] == ts[:series_name] }.empty?
          app.speaker.speak_up "Will add torrents for '#{ts[:name]}' (id '#{i}') because of proper" if Env.debug?
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
          ['TorrentSearch', 'processing_result', results, sources, limit, f, qualities.deep_dup, no_prompt, download_criteria, no_waiting, grab_all, search_category],
          1,
          "#{Thread.current[:object]}torrent",
          4
      )
    end
  end

  def self.search_from_torrents(torrent_sources:, filter_sources:, category:, destination: {}, no_prompt: 0, qualities: {}, download_criteria: {}, search_category: nil, no_waiting: 0, grab_all: 0)
    search_list, existing_files = {}, {}
    filter_sources.each do |t, s|
      slist, elist = Library.process_filter_sources(source_type: t, source: s, category: category, no_prompt: no_prompt, destination: destination, qualities: qualities)
      search_list.merge!(slist)
      existing_files.merge!(elist)
    end
    app.speaker.speak_up "Empty searchlist" if search_list.empty?
    app.speaker.speak_up "No trackers source configured!" if (torrent_sources['trackers'].nil? || torrent_sources['trackers'].empty?)
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
        no_waiting: no_waiting,
        grab_all: grab_all,
        search_category: search_category
    )
  end

  def self.torrent_download(torrent, no_prompt = 0, no_waiting = 0, remove_others = [], category = '')
    waiting_until = waiting_time_set(torrent)
    torrent[:category] = category
    if no_waiting.to_i == 0 && download_now?(waiting_until).to_i == 1 && no_prompt.to_i > 0
      app.speaker.speak_up("Setting timeframe for '#{torrent[:name]}' on #{torrent[:tracker]} to #{waiting_until}", 0) if torrent[:in_db].to_i == 0
      torrent[:download_now] = 1
    else
      app.speaker.speak_up("Adding torrent #{torrent[:name]} on #{torrent[:tracker]} to the torrents to download")
      torrent[:download_now] = 2
    end
    if torrent[:in_db]
      app.db.update_rows('torrents', {:status => torrent[:download_now], :waiting_until => waiting_until}, {:name => torrent[:name]})
    else
      app.db.insert_row('torrents', {
          :identifier => torrent[:identifier],
          :identifiers => torrent[:identifiers],
          :name => torrent[:name],
          :tattributes => Cache.object_pack(torrent.select { |k, _| ![:identifier, :identifiers, :name, :download_now].include?(k) }),
          :waiting_until => waiting_until,
          :status => torrent[:download_now]
      })
    end
    if torrent[:download_now] == 2
      remove_others.each do |tname|
        t = app.db.get_rows('torrents', {:name => tname}).first
        next if t.nil? || t[:status].to_i > 3
        app.speaker.speak_up "Will remove torrent '#{tname}' with same identifier than torrent '#{torrent[:name]}' (tid '#{t[:torrent_id]}')" if Env.debug?
        app.t_client.delete_torrent(tname, t[:torrent_id], 0, 1)
      end
    end
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding, 2))
  end

  def self.waiting_time_set(torrent)
    (Time.parse(torrent[:added].to_s) rescue Time.now) + torrent[:timeframe_quality].to_i + torrent[:timeframe_tracker].to_i + torrent[:timeframe_size].to_i
  end

end
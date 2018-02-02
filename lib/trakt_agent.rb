class TraktAgent
  def self.access_token(vals)
    {"access_token" => vals[:access_token],
     "token_type" => "bearer",
     "expires_in" => (Time.parse(vals[:expires_in])-Time.now).to_i,
     "refresh_token" => vals[:refresh_token],
     "scope" => "public"}
  end

  def self.add_to_list(items, list_name = '', type = 'movies')
    return if Env.pretend?
    authenticate!
    items = [items] unless items.is_a?(Array)
    items.map! { |i| i.merge({'collected_at' => Time.now}) } if list_name == 'collection'
    begin
      tries ||= 3
      $trakt.sync.add_or_remove_item('add', list_name, type, items)
    rescue
      retry unless (tries -= 1).to_i <= 0
    end
  end

  def self.clean_list(list_to_clean = Cache.queue_state_get('cleanup_trakt_list'))
    return if Env.pretend?
    list_to_clean.each do |list_name, list|
      list.map { |m| m[:t] }.uniq.each do |type|
        l = list.select { |m| m[:t] == type }.map { |m| m[:c] }
        $speaker.speak_up "Cleaning trakt list '#{list_name}' (type #{type}, #{l.count} elements)" if Env.debug?
        TraktAgent.remove_from_list(l, list_name, type)
      end
      Cache.queue_state_remove('cleanup_trakt_list', list_name)
    end
  end

  def self.create_list(name, description, privacy = 'private', display_numbers = false, allow_comments = true)
    return if Env.pretend?
    authenticate!
    $trakt.list.create_list({
                                'name' => name,
                                'description' => description,
                                'privacy' => privacy,
                                'display_numbers' => display_numbers,
                                'allow_comments' => allow_comments
                            })
  end

  def self.authenticate!
    raise 'No trakt account configured' unless $trakt
    token_rows = $db.get_rows('trakt_auth', {:account => $trakt_account})
    token_row = token_rows.first
    if token_row.nil? || Time.parse(token_row[:expires_in]) < Time.now
      if Daemon.is_daemon? && !Thread.current[:current_daemon]
        Report.sent_out('Expired TraktAgent token', nil, 'Your trakt authentication is not set or has expired.
Please run \'librarian trakt refresh_auth\' to set it up!')
        return
      else
        token = $trakt.access_token
        $db.delete_rows('trakt_auth', token_row) if token_row
        $db.insert_row('trakt_auth', {
            :account => $trakt_account,
            :access_token => token['access_token'],
            :refresh_token => token['refresh_token'],
            :expires_in => Time.now + token['expires_in'].to_i.seconds
        }) if token
      end
    else
      token = self.access_token(token_row)
    end
    $trakt.token = token
  end

  def self.get_history(type, trakt_id = '')
    authenticate!
    h = $trakt.list.get_history(type, trakt_id)
    return [] if h.is_a?(Hash) && h['error']
    h
  rescue => e
    $speaker.tell_error(e, "traktList.get_history")
    []
  end

  def self.get_watched(type, complete = 0)
    authenticate!
    h, k = [], []
    if $config['kodi']
      case type
        when 'movies'
          k = Xbmc::VideoLibrary.get_movies({:properties => ["title", "year", "lastplayed", "playcount", "imdbnumber"],
                                             :sort => {:order => 'ascending', :method => 'label'}})
        when 'shows', 'episodes'
          k = Xbmc::VideoLibrary.get_tv_shows({:properties => ["title", "year", "playcount", "episode", "imdbnumber", "premiered", "lastplayed", "season", "watchedepisodes"],
                                               :sort => {:order => 'ascending', :method => 'label'}})
      end
      k.each do |m|
        next if complete.to_i > 0 && ['shows', 'episodes'].include?(type) && m['watchedepisodes'].to_i < m['episode'].to_i
        next if complete.to_i < 0 && ['shows', 'episodes'].include?(type) && m['watchedepisodes'].to_i >= m['episode'].to_i
        next if type == 'movies' && m['playcount'].to_i == 0
        c = {}
        c[type[0...-1]] = m
        c[type[0...-1]]['ids'] = {'imdb' => m['imdbnumber']}
        c[type[0...-1]]['title'].gsub!(/ \(\d+\)$/, '').to_s
        c['plays'] = m['playcount']
        c['last_watched_at'] = m['lastplayed']
        h << c
      end
    end
    h = $trakt.list.get_watched(type) if h.nil? || h.empty?
    return [] if h.is_a?(Hash) && h['error']
    h
  rescue => e
    $speaker.tell_error(e, "TraktAgent.get_watched")
    []
  end

  def self.filter_trakt_list(list, type, filter_type, exception = nil, add_only = 0, old_list = [], cr_value = 0, folder = '')
    print "Ok, will filter all #{filter_type.gsub('_', ' ')} items, it can take a long time..."
    complete = if filter_type.include?('entirely')
                 1
               elsif filter_type.include?('partially')
                 -1
               else
                 0
               end
    watched_videos = nil
    list.reverse_each do |item|
      delete_it = 0
      next if add_only.to_i > 0 && search_list(type[0...-1], item, old_list)
      title = item[type[0...-1]]['title']
      next if exception && exception.include?(title)
      case filter_type
        when 'watched', 'entirely_watched', 'partially_watched'
          break if cr_value.to_i != 0
          watched_videos = get_watched(type, complete) if watched_videos.nil?
          watched_videos.each do |h|
            if h[type[0...-1]] && h[type[0...-1]]['ids']
              h[type[0...-1]]['ids'].each do |k, id|
                if item[type[0...-1]]['ids'][k] && item[type[0...-1]]['ids'][k].gsub(/\D/, '').to_i == id.gsub(/\D/, '').to_i
                  delete_it = 1
                  break
                end
              end
            end
            if item[type[0...-1]]['title']+item[type[0...-1]]['year'].to_s == h[type[0...-1]]['title']+h[type[0...-1]]['year'].to_s
              delete_it = 1
              break
            end
          end
        when 'ended', 'not_ended'
          break if cr_value.to_i != 0
          ids = item[type[0...-1]]['ids'] || {}
          _, show = MediaInfo.tv_show_search(title, 1, ids)
          if show.nil? || (show.status.downcase == filter_type || (filter_type == 'not_ended' && show.status.downcase != 'ended'))
            delete_it = 1
          end
        when 'released_before', 'released_after'
          next unless type == 'movies'
          break if cr_value.to_i == 0
          next if item[type[0...-1]]['year'].to_i == 0
          delete_it = 1 if item[type[0...-1]]['year'].to_i > cr_value.to_i && filter_type == 'released_before'
          delete_it = 1 if item[type[0...-1]]['year'].to_i < cr_value.to_i && filter_type == 'released_after'
        when 'days_older', 'days_newer'
          next unless type == 'movies'
          break if cr_value.to_i == 0
          folders = FileUtils.search_folder(folder, {'regex' => StringUtils.title_match_string(title, 0), 'return_first' => 1, filter_type => cr_value})
          delete_it = 1 unless folders.first
      end
      if delete_it > 0
        $speaker.speak_up("Removing #{type} '#{title}' from list because of criteria '#{filter_type}'", 0) if Env.debug?
        list.delete(item)
      end
      print '.'
    end
    $speaker.speak_up('done!', 0)
    list
  rescue => e
    $speaker.tell_error(e, "TraktAgent.filter_trakt_list")
    list
  end

  def self.list(name = 'watchlist', type = 'movies')
    authenticate!
    case name
      when 'watchlist'
        list = $trakt.list.watchlist(type)
        list.sort_by! { |i| i[type[0...-1]]['year'] ? i[type[0...-1]]['year'] : (Time.now+100.years).year }
      when 'collection'
        list = $trakt.list.collection(type)
      when 'lists'
        list = $trakt.list.get_user_lists
      else
        list = $trakt.list.list(name)
    end
    list
  rescue => e
    $speaker.tell_error(e, "TraktAgent.list")
    []
  end

  def self.list_cache_add(list_name, type, item, id = Time.now.to_i)
    ex = Cache.queue_state_get('cleanup_trakt_list')[list_name] || []
    Cache.queue_state_add_or_update('cleanup_trakt_list', {list_name => ex.push({:id => id, :c => item, :t => type})})
  end

  def self.list_cache_remove(item_id)
    list_cache = Cache.queue_state_get('cleanup_trakt_list')
    list_cache.each do |k, list|
      list_cache[k] = list.select { |x| x[:id] != item_id }
    end
    Cache.queue_state_add_or_update('cleanup_trakt_list', list_cache)
  end

  def self.parse_custom_list(items)
    parsed = {}
    items.each do |i|
      t = i['type']
      type = ['show', 'season', 'episode'].include?(t) ? 'shows' : 'movies'
      parsed[type] = {} unless parsed[type]
      t_title = i[type[0...-1]]['title']
      parsed[type][t_title] = i[type[0...-1]] if parsed[type][t_title].nil?
      parsed[type][t_title]['ids'] = i[type[0...-1]]['ids'] if parsed[type][t_title]['ids'].nil? && i[type[0...-1]]['ids']
      next unless ['season', 'episode'].include?(t)
      parsed[type][t_title]['seasons'] = {} if parsed[type][t_title]['seasons'].nil?
      s_number = i[t][t == 'season' ? 'number' : 'season']
      parsed[type][t_title]['seasons'][s_number] = t == 'season' ? i[t] : {'number' => i[t]['season']} if parsed[type][t_title]['seasons'][s_number].nil?
      parsed[type][t_title]['seasons'][s_number]['ids'] = i['season']['ids'] if parsed[type][t_title]['seasons'][s_number].nil? && i['season']['ids']
      next unless t == 'episode'
      parsed[type][t_title]['seasons'][s_number]['episodes'] = [] if parsed[type][t_title]['seasons'][s_number]['episodes'].nil?
      parsed[type][t_title]['seasons'][s_number]['episodes'] << i[t]
    end
    parsed.each do |k, cat|
      cat.each do |t, c|
        parsed[k][t]['seasons'] = c['seasons'].map { |s, v| v } if c['seasons']
      end
      parsed[k] = cat.map { |s, i| i }
    end
    parsed
  end

  def self.refresh_auth
    authenticate!
  end

  def self.remove_from_list(items, list = 'watchlist', type = 'movies')
    return if Env.pretend?
    authenticate!
    begin
      tries = 3
      $trakt.sync.add_or_remove_item('remove', list, type, items)
    rescue
      retry unless (tries -= 1).to_i <= 0
    end
  end

  def self.search_list(type, item, list)
    title = item[type] && item[type]['title'] ? item[type]['title'] : nil
    return false unless title && list && !list.empty?
    !list.select { |x| x['title'] && x['title'] == title }.empty?
  end

  def self.method_missing(name, *args)
    m = name.to_s.split('__')
    return unless m[0] && m[1]
    authenticate!
    if args.empty?
      eval("$trakt.#{m[0]}").method(m[1]).call
    else
      eval("$trakt.#{m[0]}").method(m[1]).call(*args)
    end
  rescue => e
    $speaker.tell_error(e, "TraktAgent.#{name}")
  end
end
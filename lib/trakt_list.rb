class TraktList
  def self.access_token(vals)
    {"access_token" => vals['access_token'],
     "token_type" => "bearer",
     "expires_in" => (Time.parse(vals['expires_in'])-Time.now).to_i,
     "refresh_token" => vals['refresh_token'],
     "scope" => "public"}
  end

  def self.add_to_list(items, list_type, list_name = '', type = 'movies')
    return if $env_flags['pretend'] > 0
    authenticate!
    items = [items] unless items.is_a?(Array)
    items.map! { |i| i.merge({'collected_at' => TIme.now}) } if list_type == 'collection'
    $trakt.sync.add_or_remove_item('add', list_type, type, items, list_name)
  end

  def self.clean_list(list_name)
    return if $env_flags['pretend'] > 0
    $cleanup_trakt_list.each do |movie|
      TraktList.remove_from_list(movie[:c], list_name, movie[:t])
    end
  end

  def self.create_list(name, description, privacy = 'private', display_numbers = false, allow_comments = true)
    return if $env_flags['pretend'] > 0
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
    token_rows = $db.get_rows('trakt_auth', {'account' => $trakt_account})
    token_row = token_rows.first
    if token_row.nil? || Time.parse(token_row['expires_in']) < Time.now
      token = $trakt.access_token
      $db.execute("delete from trakt_auth") if token_row
      $db.insert_row('trakt_auth', {
          'account' => $trakt_account,
          'access_token' => token['access_token'],
          'refresh_token' => token['refresh_token'],
          'created_at' => Time.now,
          'expires_in' => Time.now + token['expires_in'].to_i.seconds
      }) if token
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
        c[type[0...-1]]['title'].gsub!(/ \(\d+\)$/,'').to_s
        c['plays'] = m['playcount']
        c['last_watched_at'] = m['lastplayed']
        h << c
      end
    end
    h = $trakt.list.get_watched(type) if h.nil? || h.empty?
    return [] if h.is_a?(Hash) && h['error']
    h
  rescue => e
    $speaker.tell_error(e, "TraktList.get_watched")
    []
  end

  def self.filter_trakt_list(list, type, filter_type, exception = nil, add_only = 0, old_list = [], cr_value = 0, folder = '')
    print "Ok, will filter all #{filter_type.gsub('_',' ')} items, it can take a long time..."
    complete = if filter_type.include?('entirely')
                 1
               elsif filter_type.include?('partially')
                 -1
               else
                 0
               end
    list.reverse_each do |item|
      next if add_only.to_i > 0 && search_list(type[0...-1], item, old_list)
      title = item[type[0...-1]]['title']
      next if exception && exception.include?(title)
      case filter_type
        when 'watched', 'entirely_watched', 'partially_watched'
          get_watched(type, complete).each do |h|
            if h[type[0...-1]] && h[type[0...-1]]['ids']
              h[type[0...-1]]['ids'].each do |k, id|
                if item[type[0...-1]]['ids'][k] && item[type[0...-1]]['ids'][k].gsub(/\D/,'').to_i == id.gsub(/\D/,'').to_i
                  list.delete(item)
                  break
                end
              end
            end
            if item[type[0...-1]]['title']+item[type[0...-1]]['year'].to_s == h[type[0...-1]]['title']+h[type[0...-1]]['year'].to_s
              list.delete(item)
              break
            end
          end
        when 'ended', 'not_ended'
          tvdb_id = item[type[0...-1]]['ids']['tvdb'].to_i
          search, found = MediaInfo.tv_series_search(title, tvdb_id)
          if !found || (search.status.downcase == filter_type || (filter_type == 'not_ended' && search.status.downcase != 'ended'))
            list.delete(item)
          end
        when 'released_before','released_after'
          next unless type == 'movies'
          break if cr_value.to_i == 0
          next if item[type[0...-1]]['year'].to_i == 0
          list.delete(item) if item[type[0...-1]]['year'].to_i > cr_value.to_i && filter_type == 'released_before'
          list.delete(item) if item[type[0...-1]]['year'].to_i < cr_value.to_i && filter_type == 'released_after'
        when 'days_older', 'days_newer'
          next unless type == 'movies'
          break if cr_value.to_i == 0
          folders = Utils.search_folder(folder, {'regex' => Utils.title_match_string(title), 'return_first' => 1, filter_type => cr_value})
          list.delete(item) unless folders.first
      end
      print '.'
    end
    $speaker.speak_up('done!')
    list
  rescue => e
    $speaker.tell_error(e, "TraktList.filter_trakt_list")
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
    $speaker.tell_error(e, "TraktList.list")
    []
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

  def self.remove_from_list(items, list = 'watchlist', type = 'movies')
    return if $env_flags['pretend'] > 0
    authenticate!
    if list == 'watchlist'
      $trakt.sync.mark_watched(items.map { |i| i.merge({'watched_at' => Time.now}) }, type)
    else
      $trakt.sync.add_or_remove_item('remove', list, type, items, list)
    end
  end

  def self.search_list(type, item, list)
    title = item[type] && item[type]['title'] ? item[type]['title'] : nil
    return false unless title && list && !list.empty?
    r = list.select {|x| x['title'] && x['title'] == title}
    if r && !r.empty?
      return true
    else
      return false
    end
  end
end
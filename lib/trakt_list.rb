class TraktList
  def self.access_token(vals)
    {"access_token" => vals[1],
     "token_type" => "bearer",
     "expires_in" => (Time.parse(vals[4])-Time.now).to_i,
     "refresh_token" => vals[2],
     "scope" => "public"}
  end

  def self.add_to_list(items, list_type, list_name = '', type = 'movies')
    authenticate!
    items = [items] unless items.is_a?(Array)
    items.map! { |i| i.merge({'collected_at' => TIme.now}) } if list_type == 'collection'
    $trakt.sync.add_or_remove_item('add', list_type, type, items, list_name)
  end

  def self.create_list(name, description, privacy = 'private', display_numbers = false, allow_comments = true)
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
    token_rows = $db.get_rows('trakt_auth', "account = '#{$trakt_account}'")
    token_row = token_rows.first
    if token_row.nil? || Time.parse(token_row[4]) < Time.now
      token = $trakt.access_token
      $db.insert_row('trakt_auth', [$trakt_account, token['access_token'], token['refresh_token'], Time.now, Time.now + token['expires_in'].to_i.seconds]) if token
    else
      token = self.access_token(token_row)
    end
    $trakt.token = token
  end

  def self.get_history(type, trakt_id = '')
    return [] if trakt_id.to_i <= 0
    h = $trakt.list.get_history(type, trakt_id)
    return [] if h.is_a?(Hash) && h['error']
    h
  rescue => e
    Speaker.tell_error(e, "traktList.get_history")
    []
  end

  def self.filter_trakt_list(list, type, filter_type, exception = nil)
    print "Ok, will filter all #{filter_type} items, it can take a long time..."
    type_history = filter_type == 'watched' ? get_history((type == 'shows' ? 'episodes' : type)) : []
    list.reverse_each do |item|
      title = item[type[0...-1]]['title']
      next if exception && exception.include?(title)
      case filter_type
        when 'watched'
          trakt_id = item[type[0...-1]]['ids']['trakt'].to_i
          type_history.each do |h|
            if h[type[0...-1]] && h[type[0...-1]]['ids'] && h[type[0...-1]]['ids']['trakt'] && h[type[0...-1]]['ids']['trakt'].to_i == trakt_id
              list.delete(item)
              break
            end
          end
        when 'ended', 'not ended'
          tvdb_id = item[type[0...-1]]['ids']['tvdb'].to_i
          search, found = MediaInfo.tv_series_search(title, tvdb_id)
          if !found || (search.status.downcase == filter_type || (filter_type == 'not ended' && search.status.downcase != 'ended'))
            list.delete(item)
          end
      end
      print '...'
    end
    Speaker.speak_up('done!')
    list
  rescue => e
    Speaker.tell_error(e, "TraktList.filter_trakt_list")
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
    Speaker.tell_error(e, "TraktList.list")
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
        parsed[k][t]['seasons'] = c['seasons'].map {|s,v| v } if c['seasons']
      end
      parsed[k] = cat.map {|s, i| i }
    end
    parsed
  end

  def self.remove_from_list(items, list = 'watchlist', type = 'movies')
    authenticate!
    if list == 'watchlist'
      $trakt.sync.mark_watched(items.map { |i| i.merge({'watched_at' => Time.now}) }, type)
    else
      $trakt.sync.add_or_remove_item('remove', list, type, items, list)
    end
  end
end
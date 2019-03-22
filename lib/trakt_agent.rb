class TraktAgent

  def self.add_to_list(items, list_name = '', type = 'movies')
    return if Env.pretend?
    items = [items] unless items.is_a?(Array)
    items.map! {|i| i.merge({'collected_at' => Time.now})} if list_name == 'collection'
    begin
      tries ||= 3
      $trakt.sync.add_or_remove_item('add', list_name, type, items)
    rescue
      retry unless (tries -= 1).to_i <= 0
    end
  end

  def self.create_list(name, description, privacy = 'private', display_numbers = false, allow_comments = true)
    return if Env.pretend?
    $trakt.list.create_list({
                                'name' => name,
                                'description' => description,
                                'privacy' => privacy,
                                'display_numbers' => display_numbers,
                                'allow_comments' => allow_comments
                            })
  end

  def self.get_history(type, trakt_id = '')
    h = $trakt.list.get_history(type, trakt_id)
    return [] if h.is_a?(Hash) && h['error']
    h
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    []
  end

  def self.get_watched(type, complete = 0)
    $speaker.speak_up(Utils.arguments_dump(binding)) if Env.debug?
    get_watched = BusVariable.new('get_watched', Vash)
    cache_name = "#{type}#{complete}"
    return get_watched[cache_name] if get_watched[cache_name]
    h, k = [], []
    case type
    when 'movies'
      k = Kodi.get_media(type, ["title", "year", "lastplayed", "playcount", "imdbnumber"])
    when 'shows', 'episodes'
      k = Kodi.get_media('shows', ["title", "year", "playcount", "episode", "imdbnumber", "premiered", "lastplayed", "season", "watchedepisodes"])
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
    if h.nil? || h.empty?
      k = $trakt.list.get_watched(type, '?extended=noseasons')
      return [] if h.is_a?(Hash) && h['error']
      k.each do |item|
        _, info = ['shows', 'episodes'].include?(type) ? MediaInfo.tv_show_get(item['show']['ids']) : nil
        next if complete.to_i > 0 && ['shows', 'episodes'].include?(type) && item['plays'].to_i < info.aired_episodes.to_i
        next if complete.to_i < 0 && ['shows', 'episodes'].include?(type) && item['plays'].to_i >= info.aired_episodes.to_i
        next if type == 'movies' && item['plays'].to_i == 0
        h << item
      end
    end
    get_watched[cache_name, CACHING_TTL] = h
    h
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    []
  end

  def self.filter_trakt_list(list, type, filter_type, exception = nil, add_only = 0, old_list = [], cr_value = 0, folder = '')
    $speaker.speak_up("Ok, will filter all #{filter_type.gsub('_', ' ')} items, it can take a long time...", 0)
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
      $speaker.speak_up "Will filter item titled '#{title}' for #{filter_type.gsub('_', ' ')}" if Env.debug?
      if exception && exception.include?(title)
        $speaker.speak_up "Skipping because '#{title}' is included in exceptions" if Env.debug?
        next
      end
      case filter_type
      when 'watched', 'entirely_watched', 'partially_watched'
        break if cr_value.to_i != 0
        watched_videos = get_watched(type, complete) if watched_videos.nil?
        watched_videos.each do |h|
          if h[type[0...-1]] && h[type[0...-1]]['ids']
            h[type[0...-1]]['ids'].each do |k, id|
              if item[type[0...-1]]['ids'][k].to_s != '' && item[type[0...-1]]['ids'][k].to_s == id.to_s
                delete_it = 1
                break
              end
            end
          end
          if item[type[0...-1]]['title'] == h[type[0...-1]]['title'] &&
              Utils.match_release_year(item[type[0...-1]]['year'].to_i, h[type[0...-1]]['year'].to_i)
            delete_it = 1
            break
          end
        end
      when 'ended', 'not_ended'
        break if cr_value.to_i > 1
        ids = item[type[0...-1]]['ids'] || {}
        _, show = MediaInfo.tv_show_search(title, 1, ids)
        if show &&
            ((cr_value.to_i == 0 && (show.status.downcase == filter_type || (filter_type == 'not_ended' && show.status.downcase != 'ended'))) ||
                (cr_value.to_i == 1 && !show.anthology? && filter_type == 'not_ended' && show.status.downcase != 'ended'))
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
        $speaker.speak_up("Removing #{type} '#{title}' from list because of criteria '#{filter_type}'='#{cr_value}'") if Env.debug?
        list.delete(item)
      end
      print '.'
    end
    $speaker.speak_up('done!', 0)
    list
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    list
  end

  def self.list(name = 'watchlist', type = 'movies')
    list, t = [], 0
    while list.empty? && t < 4
      list = list_fetch(name, type)
      t += 1
    end
    list
  end

  def self.list_fetch(name, type)
    tries ||= 3
    case name
    when 'watchlist'
      list = $trakt.list.watchlist(type)
      list.sort_by! {|i| i[type[0...-1]]['year'] ? i[type[0...-1]]['year'] : (Time.now + 100.years).year}
    when 'collection'
      list = $trakt.list.collection(type)
    when 'lists'
      list = $trakt.list.get_user_lists
    else
      list = $trakt.list.list(name)
    end
    list
  rescue => e
    if (tries -= 1).to_i >= 0
      sleep 120
      retry
    else
      $speaker.tell_error(e, Utils.arguments_dump(binding))
      []
    end
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
        parsed[k][t]['seasons'] = c['seasons'].map {|s, v| v} if c['seasons']
      end
      parsed[k] = cat.map {|s, i| i}
    end
    parsed
  end

  def self.remove_from_list(items, list = 'watchlist', type = 'movies')
    $speaker.speak_up "Cleaning trakt list '#{list}' (type #{type}, #{items.count} elements)" if Env.debug?
    tries, result = 3, false
    return result if Env.pretend?
    begin
      $trakt.sync.add_or_remove_item('remove', list, type, items)
      result = true
    rescue
      retry unless (tries -= 1).to_i <= 0
    end
    result
  end

  def self.search_list(type, item, list)
    title = item[type] && item[type]['title'] ? item[type]['title'] : nil
    return false unless title && list && !list.empty?
    !list.select {|x| x['title'] && x['title'] == title}.empty?
  end

  def self.method_missing(name, *args)
    m = name.to_s.split('__')
    return unless m[0] && m[1]
    if args.empty?
      eval("$trakt.#{m[0]}").method(m[1]).call
    else
      eval("$trakt.#{m[0]}").method(m[1]).call(*args)
    end
  rescue => e
    $speaker.tell_error(e, "TraktAgent.#{name}")
  end
end
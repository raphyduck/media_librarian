require File.dirname(__FILE__) + '/vash'
class MediaInfo

  @tv_episodes = {}
  @media_folders = Vash.new
  @cache_metadata = Vash.new

  def self.cache_add(type, keyword, result, full_save = nil)
    $speaker.speak_up "Refreshing cache for #{keyword}#{' will not be saved to db' if full_save.nil?}" if Env.debug?
    @cache_metadata[type.to_s + keyword.to_s, CACHING_TTL] = result.clone
    r = Utils.object_pack(result)
    $db.insert_row('metadata_search', {
        :keywords => keyword,
        :type => cache_get_enum(type),
        :result => r,
    }) if cache_get_enum(type) && full_save && r
  end

  def self.cache_expire(row)
    $db.delete_rows('metadata_search', row)
  end

  def self.cache_get(type, keyword, expiration = 365)
    return nil unless cache_get_enum(type)
    return @cache_metadata[type.to_s + keyword.to_s] if @cache_metadata[type.to_s + keyword.to_s]
    res = $db.get_rows('metadata_search', {:type => cache_get_enum(type),
                                           :keywords => keyword}
    )
    res.each do |r|
      if Time.parse(r[:created_at]) < Time.now - expiration.days && !Env.pretend?
        cache_expire(r)
        next
      end
      result = Utils.object_unpack(r[:result])
      @cache_metadata[type.to_s + keyword.to_s, CACHING_TTL] = result
      return result
    end
    nil
  end

  def self.cache_get_enum(type)
    METADATA_SEARCH[:type_enum][type.to_sym] rescue nil
  end

  def self.cache_get_mediatype_enum(type)
    METADATA_SEARCH[:media_type][type.to_sym][:enum] rescue nil
  end

  def self.clean_title(title, complete = 0)
    t = title.clone
    t.gsub!(/\(I+\) /, '')
    t.gsub!(' (Video)', '')
    t.gsub!(/\(TV .+\)/, '')
    t.gsub!(/(&#x27;|&#039;)/, '')
    if complete
      t.gsub!(/\(?US[ \)]{0,2}$/, '')
      t.downcase!
      t.gsub!(/[ \(\)\.\:,\'\/-]/, '')
      t.gsub!(/(&|and)/, '')
    end
    t
  end

  def self.clear_year(title, strict = 1)
    reg = strict.to_i > 0 ? '[ \.]\(?\d{4}[\) ]?$' : '[\( \.]\d{4}([ \)\.](.*))?$'
    title.gsub(Regexp.new(reg), ' \2')
  end

  def self.detect_real_title(name, type)
    case type
      when 'movies'
        name = (name.match(/^(\[[^\]])?(.*[\. ]\(?\d{4}\)?)[\. ]/i)[2].to_s.gsub('.', ' ') rescue name)
      when 'shows'
        name = (name.match(/^(\[[^\]])?(.*)([s\. _\^\[]\d{1,3}[ex]\d{1,4}|s\d{1,3}[\. ])/i)[2].to_s.gsub('.', ' ') rescue name)
        name = name.gsub(/[\. ]\(?US[\). ]{0,2}$/, '')
    end
    name
  end

  def self.filter_quality(filename, qualities)
    timeframe = ''
    return timeframe, true if qualities.nil? || qualities.empty?
    ['RESOLUTIONS', 'SOURCES', 'CODECS', 'AUDIO', 'LANGUAGES'].each do |t|
      file_q = parse_qualities(filename, eval(t))[0].to_s
      if file_q.empty?
        qualities['assume_quality'].to_s.split(' ').each do |q|
          if eval(t).include?(q)
            file_q << q
            break
          end
        end
      end
      qualities['min_quality'].to_s.split(' ').each do |q|
        if eval(t).include?(q) && (file_q.empty? || eval(t).index(q) < eval(t).index(file_q))
          $speaker.speak_up "'#{filename}' is of lower quality than the minimum required (#{q}), removing from list" if Env.debug?
          return timeframe, false
        end
      end
      qualities['max_quality'].to_s.split(' ').each do |q|
        if eval(t).include?(q) && eval(t).index(q) > eval(t).index(file_q)
          $speaker.speak_up "'#{filename}' is of higher quality than the maximum allowed (#{q}), removing from list" if Env.debug?
          return timeframe, false
        end
      end
      (qualities['target_quality'] || qualities['max_quality']).to_s.split(' ').each do |q|
        if eval(t).include?(q) && timeframe == '' && eval(t).index(q) < eval(t).index(file_q)
          $speaker.speak_up "'#{filename}' is of lower quality than the target quality (#{q}), setting timeframe '#{qualities['timeframe']}'" if Env.debug?
          timeframe = qualities['timeframe'].to_s
        end
      end
    end
    return timeframe, true
  end

  def self.identify_metadata(filename, type, item_name = '', item = nil, no_prompt = 0, folder_hierarchy = {}, base_folder = '')
    metadata = {}
    ep_filename = File.basename(filename)
    item_name, item = identify_title(filename, type, no_prompt, (folder_hierarchy[type] || FOLDER_HIERARCHY[type]), base_folder) if item_name.to_s == '' || item.nil?
    return nil if item.nil? && (no_prompt.to_i > 0 || item_name.to_s == '')
    metadata['quality'] = metadata['quality'] ||
        parse_qualities(File.basename(ep_filename)).join('.')
    metadata['proper'], _ = identify_proper(ep_filename)
    metadata['extension'] = ep_filename.gsub(/.*\.(\w{2,4}$)/, '\1')
    case type
      when 'shows'
        metadata['episode_season'], ep_nb = TvSeries.identify_tv_episodes_numbering(ep_filename)
        if metadata['episode_season'] == '' || ep_nb.empty?
          metadata['episode_season'] = $speaker.ask_if_needed("Season number not recognized for #{ep_filename}, please enter the season number now (empty to skip)", no_prompt, '').to_i
          ep_nb = [{:ep => $speaker.ask_if_needed("Episode number not recognized for #{ep_filename}, please enter the episode number now (empty to skip)", no_prompt, '').to_i, :part => 0}]
        end
        _, @tv_episodes[item_name] = tv_episodes_search(item_name, no_prompt, item) if @tv_episodes[item_name].nil?
        episode_name = []
        episode_numbering = []
        ep_nb.each do |n|
          tvdb_ep = !@tv_episodes[item_name].empty? && metadata['episode_season'] != '' && n[:ep].to_i > 0 ? @tv_episodes[item_name].select { |e| e.season_number == metadata['episode_season'].to_i.to_s && e.number == n[:ep].to_s }.first : nil
          episode_name << (tvdb_ep.nil? ? '' : tvdb_ep.name.to_s.downcase)
          if n[:ep].to_i > 0 && metadata['episode_season'] != ''
            episode_numbering << "S#{format('%02d', metadata['episode_season'].to_i)}E#{format('%02d', n[:ep])}#{'.' + n[:part].to_s if n[:part].to_i > 0}."
          end
        end
        metadata['episode_name'] = episode_name.join(' ')[0..50]
        metadata['episode_numbering'] = episode_numbering.join(' ')
        metadata['series_name'] = item_name
        metadata['is_found'] = (metadata['episode_numbering'] != '')
      when 'movies'
        metadata['movies_name'] = item_name
        metadata['is_found'] = true
    end
    metadata
  end

  def self.identify_proper(filename)
    p = File.basename(filename).downcase.match(/[\. ](proper|repack)[\. ]/).to_s.gsub(/[\. ]/, '').gsub(/(repack|real)/, 'proper')
    return p, (p != '' ? 1 : 0)
  end

  def self.identify_title(filename, type, no_prompt = 0, folder_level = 2, base_folder = '', ids = {})
    ids = {} if ids.nil?
    in_path = Utils.is_in_path(@media_folders.map { |k, _| k }, filename)
    return @media_folders[in_path] if in_path && !@media_folders[in_path].nil?
    title, item = nil, nil
    filename, _ = Utils.get_only_folder_levels(filename.gsub(base_folder, ''), folder_level.to_i)
    r_folder, jk = filename, 0
    while item.nil?
      t_folder, r_folder = Utils.get_top_folder(r_folder)
      case type
        when 'movies'
          if item.nil? && t_folder == r_folder
            t_folder = detect_real_title(t_folder, type)
            jk += 1
          end
          title, item = movie_lookup(t_folder, no_prompt, 0, ids['imdb'])
        when 'shows'
          if item.nil? && t_folder == r_folder
            t_folder = detect_real_title(t_folder, type)
            jk += 1
          end
          title, item = tv_show_search(t_folder, no_prompt, ids['tvdb'])
        else
          title = File.basename(filename).downcase.gsub(REGEX_QUALITIES, '').gsub(/\.{\w{2,4}$/, '')
      end
      break if t_folder == r_folder || jk > 0
    end
    @media_folders[base_folder + filename.gsub(r_folder, ''), CACHING_TTL] = [title, item] unless @media_folders[base_folder + filename.gsub(r_folder, '')] || (base_folder + filename.gsub(r_folder, '')).to_s == ''
    return title, item
  end

  def self.identify_release_year(filename)
    filename.match(/\((\d{4})\)$/)[1].to_i rescue 0
  end

  def self.media_qualities(filename)
    q = {}
    ['RESOLUTIONS', 'SOURCES', 'CODECS', 'AUDIO', 'LANGUAGES'].each do |t|
      q[t.downcase] = parse_qualities(filename, eval(t)).first.to_s
    end
    q['proper'] = identify_proper(filename)[1]
    q
  end

  def self.media_add(item_name, type, full_name, identifiers, attrs = {}, file_attrs = {}, file = {}, data = {})
    identifiers = [identifiers] unless identifiers.is_a?(Array)
    id = identifiers.join
    obj = {
        :full_name => full_name,
        :identifier => id,
        :identifiers => identifiers
    }
    data[id] = {
        :type => type,
        :name => item_name
    }.merge(obj).merge(attrs.deep_dup) if data[id].nil?
    data[id][:files] = [] if data[id][:files].nil?
    data[id][:files] << file.merge(obj).merge(file_attrs) unless file.nil? || file.empty? || !data[id][:files].select { |f| f[:name].to_s == file[:name].to_s }.empty?
    if attrs[:show]
      data[:shows] = {} if data[:shows].nil?
      data[:shows][item_name] = attrs[:show]
    end
    if attrs[:movie]
      data[:movies] = {} if data[:movies].nil?
      data[:movies][item_name] = attrs[:movie]
    end
    data
  end

  def self.media_exist?(files, identifiers, f_type = nil)
    !media_get(files, identifiers, f_type).empty?
  end

  def self.media_get(files, identifiers, f_type = nil)
    eps = {}
    identifiers = [identifiers.to_s] unless identifiers.is_a?(Array)
    identifiers.each do |i|
      eps.merge!(files.select { |id, f| id.to_s.include?(i) && (f_type.nil? || f[:f_type].nil? || f_type.to_s == f[:f_type].to_s) })
    end
    eps
  end

  def self.media_chose(title, items, keys, no_prompt = 0, search_alt = 0)
    item = nil
    unless (items || []).empty?
      results = items.map { |m| [clean_title(m[keys['name']]), m[keys['url']]] }
      results += [['Edit title manually', '']]
      (0..results.count-2).each do |i|
        show_year = items[i][keys['year']].match(/\d{4}/).to_s.to_i
        year = identify_release_year(title)
        if clean_title(clear_year(items[i][keys['name']]), 1) == clean_title(clear_year(title), 1) &&
            (year == 0 || show_year == 0 || (show_year < year + 1 && show_year > year - 1)) && (search_alt.to_i == 0 || no_prompt.to_i > 0)
          choice = i
        elsif no_prompt.to_i == 0
          $speaker.speak_up("Alternatives titles found for #{title}:")
          results.each_with_index do |m, idx|
            $speaker.speak_up("#{idx + 1}: #{m[0]}#{' (info: ' + URI.escape(m[1]) + ')' if m[1].to_s != ''}")
          end
          choice = $speaker.ask_if_needed("Enter the number of the chosen title (empty to skip): ", no_prompt, 1).to_i - 1
        else
          choice = -1
        end
        next if choice < 0 || choice >= results.count
        t = results[choice]
        if t[0] == 'Edit title manually'
          $speaker.speak_up('Enter the title to look for:')
          title = STDIN.gets.strip
          break
        end
        item = items[choice]
        title = item[keys['name']]
        break
      end
    end
    return title, item
  end

  def self.movie_lookup(title, no_prompt = 0, search_alt = 0, imdb_id = '')
    cached = cache_get('movie_lookup', title)
    return cached if cached
    if imdb_id.to_s != ''
      exact_title, movie = $imdb.find_movie_by_id(imdb_id.to_s)
      cache_add('tv_show_search', title.to_s + imdb_id.to_s, [exact_title, movie], movie)
      return exact_title, movie unless movie.nil?
    end
    exact_title, movie = title, nil
    [clear_year(title, no_prompt), title].uniq.each do |s|
      movies = $imdb.find_by_title(s)
      movies.select! do |m|
        !(m[:title].match(/\(TV .+\)/) && !m[:title].match(/\(TV Movie\)/)) && !m[:title].match(/ \(Short\)/)
      end
      exact_title, movie = media_chose(
          title,
          movies,
          {'name' => :title, 'url' => :url, 'year' => :year},
          [no_prompt.to_i, 1-search_alt.to_i].max,
          search_alt
      )
      unless movie.nil?
        movie = $imdb.find_movie_by_id(movie[:imdb_id])
        if movie
          movie = Movie.new(Utils.object_to_hash(movie))
          exact_title = movie.title
        end
      end
      break if movie
    end
    cache_add('movie_lookup', title.to_s + imdb_id.to_s, [exact_title, movie], movie)
    return exact_title, movie
  rescue => e
    $speaker.tell_error(e, "MediaInfo.movie_title_lookup")
    cache_add('movie_lookup', title.to_s + imdb_id.to_s, [title, nil], nil)
    return title, nil
  end

  def self.parse_media_filename(filename, type, item = nil, item_name = '', no_prompt = 0, folder_hierarchy = {}, base_folder = '', file = {})
    item_name, item = MediaInfo.identify_title(filename, type, no_prompt, (folder_hierarchy[type] || FOLDER_HIERARCHY[type]), base_folder) if item.nil? || item_name.to_s == ''
    full_name, ids, info, parts = '', [], {}, []
    return full_name, ids, info unless no_prompt.to_i == 0 || item
    case type
      when 'movies'
        release = item&.release_date ? item.release_date : Time.new(MediaInfo.identify_release_year(item_name))
        ids = [Movie.identifier(item_name, release.year)]
        full_name = item_name
        info = {
            :movies_name => item_name,
            :movie => item,
            :release_date => release
        }
        parts = Movie.identify_split_files(filename)
      when 'shows'
        s, e = TvSeries.identify_tv_episodes_numbering(filename)
        ids = e.map { |n| TvSeries.identifier(item_name, s, n[:ep]) }
        f_type = 'episode'
        if ids.empty?
          ids = TvSeries.identifier(item_name, s, '')
          f_type = s != '' ? 'season' : 'series'
        end
        full_name = "#{item_name}"
        if f_type != 'series'
          full_name << " #{e.empty? ? 'S' + format('%02d', s.to_i) : e.map { |n| 'S' + format('%02d', s.to_i).to_s + 'E' + format('%02d', n[:ep].to_i).to_s }.join}"
        end
        parts = e.map { |ep| ep[:part].to_i }
        info = {
            :series_name => item_name,
            :episode_season => s.to_i,
            :episode => e.map { |ep| ep[:ep].to_i },
            :show => item,
            :f_type => f_type
        }
    end
    file[:parts] = parts unless file.nil? || file.empty?
    return full_name, ids, info
  end

  def self.parse_qualities(filename, qc = VALID_QUALITIES)
    filename.downcase.gsub(/([\. ](h|x))[\. ]?(\d{3})/, '\1\3').scan(Regexp.new('(?=(' + SEP_CHARS + '(' + qc.join('|') + ')' + SEP_CHARS + '))')).flatten.map{|q| q.gsub(/^[ \.\(\)\-](.*)[ \.\(\)\-]$/,'\1').gsub('-', '')}.uniq.flatten
  end

  def self.sort_media_files(files, qualities = {})
    sorted, r = [], []
    files.each do |f|
      qs = media_qualities(File.basename(f[:name]))
      q_timeframe, accept = filter_quality(f[:name], qualities)
      if accept
        timeframe_waiting = Utils.timeperiod_to_sec(q_timeframe).to_i
        sorted << [f[:name], qs['resolutions'], qs['sources'], qs['codecs'], qs['audio'], qs['proper'], qs['languages'], (f[:timeframe_tracker].to_i + f[:timeframe_size].to_i + timeframe_waiting)]
        r << f.merge({:timeframe_quality => Utils.timeperiod_to_sec(q_timeframe).to_i})
      end
    end
    sorted.sort_by! { |x| (AUDIO.index(x[4]) || 999).to_i }
    sorted.sort_by! { |x| (LANGUAGES.index(x[6]) || 999).to_i }
    sorted.sort_by! { |x| (CODECS.index(x[3]) || 999).to_i }
    sorted.sort_by! { |x| (SOURCES.index(x[2]) || 999).to_i }
    sorted.sort_by! { |x| (RESOLUTIONS.index(x[1]) || 999).to_i }
    sorted.sort_by! { |x| x[7].to_i }
    sorted.sort_by! { |x| -x[5].to_i }
    r.sort_by! { |f| sorted.map { |x| x[0] }.index(f[:name]) }
  end

  def self.tv_episodes_search(title, no_prompt = 0, show = nil, tvdb_id = '')
    cached = cache_get('tv_episodes_search', title.to_s + tvdb_id.to_s, 7)
    return cached if cached
    title, show = tv_show_search(title, no_prompt) unless show
    episodes = []
    unless show.nil?
      $speaker.speak_up("Using #{title} as series name", 0)
      episodes = $tvdb.get_all_episodes(show)
      episodes.map! { |e| Episode.new(Utils.object_to_hash(e)) }
    end
    cache_add('tv_episodes_search', title.to_s + tvdb_id.to_s, [show, episodes], show)
    return show, episodes
  rescue => e
    $speaker.tell_error(e, "MediaInfo.tv_episodes_search")
    cache_add('tv_episodes_search', title.to_s + tvdb_id.to_s, [nil, []], nil)
    return nil, []
  end

  def self.tv_show_get(tvdb_id)
    cached = cache_get('tv_show_get', tvdb_id.to_s)
    return cached if cached
    show = $tvdb.get_series_by_id(tvdb_id)
    show = TVMaze::Show.lookup({'thetvdb' => tvdb_id.to_i}) if show.nil?
    show = TvSeries.new(Utils.object_to_hash(show))
    title = show.name
    cache_add('tv_show_get', tvdb_id.to_s, [title, show], show)
    return title, show
  rescue => e
    $speaker.tell_error(e, "MediaInfo.tv_show_get")
    cache_add('tv_show_get', tvdb_id.to_s, ['', nil], nil)
    return '', nil
  end

  def self.tv_show_search(title, no_prompt = 0, tvdb_id = '')
    cached = cache_get('tv_show_search', title.to_s + tvdb_id.to_s)
    return cached if cached
    if tvdb_id.to_i > 0
      exact_title, show = tv_show_get(tvdb_id)
      cache_add('tv_show_search', title.to_s + tvdb_id.to_s, [exact_title, show], show)
      return exact_title, show unless show.nil?
    end
    tvdb_shows = $tvdb.search(title)
    tvdb_shows = $tvdb.search(title.gsub(/ \(\d{4}\)$/, '')) if tvdb_shows.empty?
    tvdb_shows = TVMaze::Show.search(title).map { |s| Utils.object_to_hash(s) } if tvdb_shows.empty?
    tvdb_shows = TVMaze::Show.search(title.gsub(/ \(\d{4}\)$/, '')).map { |s| Utils.object_to_hash(s) } if tvdb_shows.empty?
    tvdb_shows.map! { |s| Utils.object_to_hash(TvSeries.new(s)) }
    exact_title, show = media_chose(title, tvdb_shows, {'name' => 'name', 'url' => 'url', 'year' => 'first_aired'}, no_prompt)
    exact_title, show = tv_show_get(show['tvdb_id']) if show
    cache_add('tv_show_search', title.to_s + tvdb_id.to_s, [exact_title, show], show)
    return exact_title, show
  rescue => e
    $speaker.tell_error(e, "MediaInfo.tv_episodes_search")
    cache_add('tv_show_search', title.to_s + tvdb_id.to_s, [title, nil], nil)
    return title, nil
  end

end
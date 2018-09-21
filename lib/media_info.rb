require File.dirname(__FILE__) + '/vash'
class MediaInfo

  def self.clean_title(title, complete = 0)
    t = title.clone
    t.gsub!(/\(i+\) /i, '')
    t.gsub!(/ \(video\)/i, '')
    t.gsub!(/\(tv .+\)/i, '')
    t.gsub!(/(&#x27;|&#039;)/, '')
    if complete.to_i > 0
      t.gsub!(/[\( _\.]us[ _\.\)]{0,2}$/i, '')
    end
    t
  end

  def self.clear_year(title, strict = 1)
    reg = strict.to_i > 0 ? '[ \.]\(?\d{4}\)?[ \.]?' + BASIC_EP_MATCH + '?$' : '[\( \.]\d{4}\)?([ \.](.*))?$'
    title.strip.gsub(Regexp.new(reg, Regexp::IGNORECASE), ' \1')
  end

  def self.detect_real_title(name, type, id_info = 0, complete = 1)
    name = I18n.transliterate(name.clone)
    case type
    when 'books'
      name.gsub!(/.*\/([^\/]*)/, '\1')
    when 'movies'
      m = name.match(/^(\[[^\]])?(.*[#{SPACE_SUBSTITUTE}]\(?\d{4}\)?)([#{SPACE_SUBSTITUTE}]|$)/i)
      name = m[2] if m
    when 'shows'
      ids = name.scan(Regexp.new(BASIC_EP_MATCH))
      name.gsub!(/(.*)#{ids.first[0]}.*/, '\1') unless ids.empty?
      ids = ids.map {|i| i[0] if i[0]}.join
      name.gsub!(/^(\[[^\]]+\])?(.*)/, '\2')
      name.gsub!(/[#{SPACE_SUBSTITUTE}]\(?US[\)#{SPACE_SUBSTITUTE}]{0,2}$/, '') if complete.to_i > 0
      name << "#{ids}" if id_info.to_i > 0
    end
    name.to_s.gsub(/[#{SPACE_SUBSTITUTE}]+/, ' ')
  end

  def self.filter_quality(filename, qualities)
    timeframe = ''
    unless parse_qualities(filename, ['hc']).empty?
      $speaker.speak_up "'#{filename}' contains hardcoded subtitles, removing from list" if Env.debug?
      return timeframe, false
    end
    (qualities['illegal'].is_a?(Array) ? qualities['illegal'] : [qualities['illegal'].to_s]).each do |iq|
      next if iq.to_s == ''
      if (iq.split - parse_qualities(filename)).empty?
        $speaker.speak_up "'#{filename}' has an illegal combination of quality, removing from list" if Env.debug?
        return timeframe, false
      end
    end
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
      if qualities_compare(qualities['min_quality'], t, file_q, '<', "'#{filename}' is of lower quality than the minimum required, removing from list")
        return timeframe, false
      end
      if qualities_compare(qualities['max_quality'], t, file_q, '>', "'#{filename}' is of higher quality than the maximum allowed, removing from list")
        return timeframe, false
      end
      if qualities_compare((qualities['target_quality'] || qualities['max_quality']), t, file_q, '<', "'#{filename}' is of lower quality than the target quality, setting timeframe '#{qualities['timeframe']}'") &&
          timeframe == ''
        timeframe = qualities['timeframe'].to_s
      end
    end
    return timeframe, true
  end

  def self.identify_metadata(filename, type, item_name = '', item = nil, no_prompt = 0, folder_hierarchy = {}, base_folder = '')
    metadata = {}
    ep_filename = File.basename(filename)
    metadata['quality'] = parse_qualities(File.basename(ep_filename)).join('.')
    metadata['proper'], _ = identify_proper(ep_filename)
    metadata['extension'] = FileUtils.get_extension(ep_filename)
    full_name, identifiers, info = parse_media_filename(
        filename,
        type,
        item,
        item_name,
        no_prompt,
        folder_hierarchy,
        base_folder
    )
    return metadata if ['shows', 'movies'].include?(type) && (identifiers.empty? || full_name == '')
    metadata['is_found'] = true
    metadata['part'] = info[:parts].map {|p| "part#{p}"}.join('.') unless info[:parts].nil?
    case type
    when 'shows'
      tv_episodes = BusVariable.new('tv_episodes', Vash)
      _, tv_episodes[item_name, CACHING_TTL] = tv_episodes_search(item_name, no_prompt, item) if tv_episodes[item_name].nil?
      episode_name = []
      info[:episode].each do |n|
        tvdb_ep = !tv_episodes[item_name].empty? && n[:ep] ? tv_episodes[item_name].select {|e| e.season_number.to_i == n[:s].to_i && e.number.to_i == n[:ep].to_i}.first : nil
        episode_name << (tvdb_ep.nil? ? '' : tvdb_ep.name.to_s.downcase)
      end
      metadata['episode_name'] = episode_name.join(' ')[0..50]
      metadata['is_found'] = (metadata['episode_numbering'] != '')
    when 'movies'
      metadata['movies_name'] = item_name
    end
    metadata.merge!(Utils.recursive_typify_keys({:full_name => full_name, :identifiers => identifiers}.merge(info.select{|k,_| ![:show, :movie, :book].include?(k)}), 0))
    metadata
  end

  def self.identify_proper(filename)
    p = File.basename(filename).downcase.match(/[\. ](proper|repack)[\. ]/).to_s.gsub(/[\. ]/, '').gsub(/(repack|real)/, 'proper')
    return p, (p != '' ? 1 : 0)
  end

  def self.identify_title(filename, type, no_prompt = 0, folder_level = 2, base_folder = '', ids = {})
    ids = {} if ids.nil?
    title, item, original_filename = nil, nil, nil
    media_folders = BusVariable.new('media_folders', Hash)
    media_folders[type] = Vash.new unless media_folders[type]
    in_path = FileUtils.is_in_path(media_folders[type].keys, filename)
    return media_folders[type][in_path] if in_path && !media_folders[type][in_path].nil?
    filename, _ = FileUtils.get_only_folder_levels(filename.gsub(base_folder, ''), folder_level.to_i)
    r_folder, jk = filename, 0
    while item.nil?
      t_folder, r_folder = FileUtils.get_top_folder(r_folder)
      case type
      when 'movies'
        if item.nil? && t_folder == r_folder
          original_filename = t_folder
          t_folder = detect_real_title(t_folder, type)
          jk += 1
        end
        title, item = movie_lookup(t_folder, no_prompt, ids, original_filename)
      when 'shows'
        if item.nil? && t_folder == r_folder
          original_filename = t_folder
          t_folder = detect_real_title(t_folder, type)
          jk += 1
        end
        title, item = tv_show_search(t_folder, no_prompt, ids, original_filename)
      when 'books'
        title = detect_real_title(filename, type, 1)
        title, item = Book.book_search(title, no_prompt, ids)
      else
        title = File.basename(filename).downcase.gsub(REGEX_QUALITIES, '').gsub(/\.{\w{2,4}$/, '')
      end
      break if t_folder == r_folder || jk > 0
    end
    cache_name = base_folder.to_s + filename.gsub(r_folder, '')
    media_folders[type][cache_name, CACHING_TTL] = [title, item] unless cache_name.to_s == ''
    return title, item
  end

  def self.identify_release_year(filename)
    m = filename.strip.match(/[\( \.](\d{4})[\) \.]?$/) rescue nil
    y = m ? m[1].to_i : 0
    y = 0 if y > Time.now.year + 50
    y
  end

  def self.match_titles(title, target_title, year, category)
    ep_match = true
    if category.to_s == 'shows'
      _, _, title_ep_ids = TvSeries.identify_tv_episodes_numbering(title)
      _, _, target_title_ep_ids = TvSeries.identify_tv_episodes_numbering(target_title)
      target_title_ep_ids.each {|n| ep_match = title_ep_ids.include?(n) if ep_match}
    end
    title = detect_real_title(title.strip, category, 0, 0)
    target_title = detect_real_title(target_title.strip, category, 0, 0)
    target_year = identify_release_year(target_title)
    additional_year_cond = year.to_i > 0 ? "|#{year}" : ''
    target_title.strip!
    target_title.gsub!('?', '\?')
    target_title.gsub!(/\(([^\(\)]{5,})\)/, '\(?\1\)?')
    if target_title.match(/[ \.]\(?(\d{4})\)?([#{SPACE_SUBSTITUTE}]|$)/)
      target_title.gsub!(/[ \.]\(?(\d{4})\)?([#{SPACE_SUBSTITUTE}]|$)/, '.\(?(\1' + additional_year_cond + '|US|UK)\)?\2')
    elsif category.to_s == 'movies' && year.to_i > 0
      target_title << '.\(?' << year.to_s << '\)?'
    end
    m = title.match(
        Regexp.new(
            '^\[?.{0,2}[\] ]?' + StringUtils.regexify(target_title) + '([' + SPACE_SUBSTITUTE + ']|[\&-]?e\d{1,4})?$',
            Regexp::IGNORECASE)
    ) && ep_match && Utils.match_release_year(target_year, year)
    $speaker.speak_up "title '#{title}' ('#{year}')#{' does NOT' unless m} match#{'es' if m} target_title '#{target_title}'" if Env.debug?
    m
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
    data[id][:files] << file.merge(obj).merge(file_attrs) unless file.nil? || file.empty? || !data[id][:files].select {|f| f[:name].to_s == file[:name].to_s}.empty?
    if attrs[:show]
      data[:shows] = {} if data[:shows].nil?
      data[:shows][item_name] = attrs[:show]
    end
    if attrs[:movie]
      data[:movies] = {} if data[:movies].nil?
      data[:movies][item_name] = attrs[:movie]
    end
    if attrs[:book_series].is_a?(Hash) || attrs[:book_series].is_a?(BookSeries)
      data[:book_series] = {} if data[:book_series].nil?
      series_name = attrs[:book_series].is_a?(BookSeries) ? attrs[:book_series].name : attrs[:book_series][:name]
      data[:book_series][series_name] = attrs[:book_series]
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
      eps.merge!(files.select do |id, f|
        id.to_s.include?(i) && (f_type.nil? || f[:f_type].nil? || f_type.to_s == f[:f_type].to_s)
      end)
    end
    eps
  end

  def self.media_chose(title, items, keys, category, no_prompt = 0)
    item = nil
    unless (items || []).empty?
      if keys['year']
        items.map! {|i| i[:release_year] = i[keys['year']].to_s.match(/\d{4}/).to_s.to_i; i}
        items.sort_by! {|i| i[:release_year] > 0 ? i[:release_year].to_i : Time.now.year + 3} if no_prompt.to_i == 0
      end
      results = items.map {|m| [clean_title(m[keys['name']]), m[keys['url']]]}
      results += [['Edit title manually', '']]
      (0..results.count - 2).each do |i|
        show_year = items[i][:release_year].to_i
        if match_titles(clean_title(items[i][keys['name']], 1),
                        clean_title(title, 1), show_year, category)
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

  def self.media_list_qualities(file, type = 'file')
    if file[:files]
      file[:files].select {|f| f[:type] == type}.map {|f| parse_qualities(f[:name])}.compact.flatten
    else
      []
    end
  end

  def self.media_type_get(type)
    VALID_MEDIA_TYPES.select {|_, v| v.include?(Utils.regularise_media_type(type))}.first[0]
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
  end

  def self.missing_media_add(missing_eps, type, full_name, release_date, item_name, identifiers, info, display_name = nil)
    return missing_eps if full_name == ''
    $speaker.speak_up("Missing #{display_name || full_name} (ids '#{identifiers}') (released on #{release_date})", 0)
    missing_eps = MediaInfo.media_add(item_name,
                                      type,
                                      full_name,
                                      identifiers,
                                      info,
                                      {},
                                      {},
                                      missing_eps
    )
    missing_eps
  end

  def self.movie_lookup(title, no_prompt = 0, ids = {}, original_filename = nil)
    title = StringUtils.prepare_str_search(title)
    exact_title, movie = title, nil
    cache_name = title.to_s + (ids['trakt'] || ids['imdb'] || ids['tmdb'] || ids['slug']).to_s + original_filename.to_s
    Utils.lock_block("#{__method__}_#{title}#{ids}") {
      cached = Cache.cache_get('movie_lookup', cache_name)
      return cached if cached
      if !ids.empty? &&
          (ids['imdb'].to_s != '' || ids['trakt'].to_s != '' || ids['tmdb'].to_s != '' || ids['slug'].to_s != '')
        exact_title, movie = Movie.movie_get(ids)
        Cache.cache_add('movie_lookup', cache_name, [exact_title, movie], movie)
        return exact_title, movie unless movie.nil?
      end
      [clear_year(title, no_prompt), title].uniq.each do |s|
        movies = TraktAgent.search__movies(s) rescue []
        movies = $tmdb.search('movie', {:query => s}) if $tmdb && (!movies.is_a?(Array) || movies.empty?)
        movies = [movies] unless movies.is_a?(Array)
        movies.map! do |m|
          v = if m['title']
                m
              elsif m['movie']
                m['movie']
              else
                nil
              end
          Cache.object_pack(Movie.new(Cache.object_pack(v, 1)), 1) if v
        end
        movies.compact!
        exact_title, movie = media_chose(
            title,
            movies,
            {'name' => 'name', 'url' => 'url', 'year' => 'year'},
            'movies',
            no_prompt.to_i
        )
        exact_title, movie = Movie.movie_get(movie['ids']) unless movie.nil?
        break if movie
      end
      if movie.nil? && original_filename.to_s != ''
        exact_title, movie = Kodi.kodi_lookup('movies', original_filename, exact_title)
      end
      Cache.cache_add('movie_lookup', cache_name, [exact_title, movie], movie)
    }
    return exact_title, movie
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    Cache.cache_add('movie_lookup', cache_name, [title, nil], nil)
    return title, nil
  end

  def self.parse_3d(filename, qs)
    return qs unless qs.include?('3d')
    qs.delete_if {|q| q.include?('3d')}
    if filename.downcase.match(/#{SEP_CHARS}top.{0,3}bottom#{SEP_CHARS}/)
      qs << '3d.tab'
    else
      qs << '3d.sbs'
    end
    qs
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
      s, e, _ = TvSeries.identify_tv_episodes_numbering(filename)
      ids = e.map {|n| TvSeries.identifier(item_name, n[:s], n[:ep])}
      ids = s.map {|i| TvSeries.identifier(item_name, i, '')} if ids.empty?
      ids = [TvSeries.identifier(item_name, '', '')] if ids.empty?
      episode_numbering = e.map {|n| "S#{format('%02d', n[:s].to_i)}E#{format('%02d', n[:ep])}#{'.' + n[:part].to_s if n[:part].to_i > 0}"}.join(' ')
      f_type = TvSeries.identify_file_type(filename, e, s)
      full_name = "#{item_name}"
      if f_type != 'series'
        full_name << " #{e.empty? ? s.map {|i| 'S' + format('%02d', i.to_i)}.join : episode_numbering}"
      end
      parts = e.map {|ep| ep[:part].to_i}
      info = {
          :series_name => item_name,
          :episode_season => s.map {|i| i.to_i}.join(' '),
          :episode => e,
          :episode_numbering => episode_numbering,
          :show => item,
          :f_type => f_type
      }
    when 'books'
      nb = Book.identify_episodes_numbering(filename)
      ids = [item.identifier]
      f_type = item.instance_variables.map {|a| a.to_s.gsub(/@/, '')}.include?('series') ? 'book' : 'series'
      full_name = f_type == 'book' ? item.full_name : item_name
      info = {
          :series_name => nb.to_i > 0 || f_type == 'series' ? item_name : '',
          :episode_id => nb.to_i > 0 ? nb.to_f : nil,
          :book => f_type == 'book' ? item : nil,
          :book_series => f_type == 'book' ? item.series : item
      }
    end
    file[:parts] = parts unless file.nil? || file.empty?
    return full_name, ids, info
  end

  def self.parse_qualities(filename, qc = VALID_QUALITIES)
    pq = filename.downcase.gsub(/([\. ](h|x))[\. ]?(\d{3})/, '\1\3').scan(Regexp.new('(?=((^|' + SEP_CHARS + ')(' + qc.map{|q| q.gsub('.', '[\. ]')}.join('|') + ')' + SEP_CHARS + '))')).
        map {|q| q[2]}.flatten.map do |q|
      q.gsub(/^[ \.\(\)\-](.*)[ \.\(\)\-]$/, '\1').gsub('-', '').gsub('hevc', 'x265').gsub('h26', 'x26')
    end.uniq.flatten
    pq = parse_3d(filename, pq)
    pq
  end

  def self.qualities_compare(qualities, type, qt, comparison, message = '')
    qualities.to_s.split(' ').each do |q|
      if eval(type).include?(q) && ((qt.empty? && comparison == '<') || (!qt.empty? && eval(type).index(q).send(comparison, eval(type).index(qt))))
        $speaker.speak_up "#{message} (target '#{q}')" if Env.debug? && message.to_s != ''
        return true
      end
    end
    return false
  end

  def self.qualities_array_compare(arr, comparison)
    min = []
    until arr.empty? do
      cmin = arr.shift
      arr.delete_if do |q|
        delete = false
        ['RESOLUTIONS', 'SOURCES', 'CODECS', 'AUDIO', 'LANGUAGES'].each do |t|
          if eval(t).include?(cmin) && eval(t).include?(q)
            cmin = q if eval(t).index(q).send(comparison, eval(t).index(cmin))
            delete = true
          end
        end
        delete
      end
      min << cmin if cmin
    end
    min
  end

  def self.qualities_file_filter(file, qualities)
    accept = true
    if !qualities.nil? && !qualities.empty? && (qualities['target_quality'] || qualities['max_quality'])
      existing_qualities, min_q = qualities_set_minimum(file, (qualities['target_quality'] || qualities['max_quality']))
      _, accept = filter_quality(
          '.' + existing_qualities.join('.') + '.',
          {'min_quality' => min_q}
      )
      $speaker.speak_up "Ignoring file '#{file[:full_name]}' as it is lower than target quality '#{(qualities['target_quality'] || qualities['max_quality'])}'" if Env.debug? && !accept
    end
    accept
  end

  def self.qualities_min(arr)
    qualities_array_compare(arr, '>').join(' ')
  end

  def self.qualities_max(arr)
    qualities_array_compare(arr, '<').join(' ')
  end

  def self.qualities_set_minimum(file, reference_q)
    existing_qualities = media_list_qualities(file, 'file')
    unless existing_qualities.empty?
      reference_q = qualities_max(reference_q.to_s.split(' ') + existing_qualities.dup)
      $speaker.speak_up "Already existing file(s) with an existing quality of '#{existing_qualities}', setting minimum quality to '#{reference_q}'" if Env.debug?
    end
    return existing_qualities, reference_q
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
    sorted.sort_by! {|x| (AUDIO.index(x[4]) || 999).to_i}
    sorted.sort_by! {|x| (LANGUAGES.index(x[6]) || 999).to_i}
    sorted.sort_by! {|x| -x[5].to_i}
    sorted.sort_by! {|x| (CODECS.index(x[3]) || 999).to_i}
    sorted.sort_by! {|x| (SOURCES.index(x[2]) || 999).to_i}
    sorted.sort_by! {|x| (RESOLUTIONS.index(x[1]) || 999).to_i}
    sorted.sort_by! {|x| x[7].to_i}
    r.sort_by! {|f| sorted.map {|x| x[0]}.index(f[:name])}
  end

  def self.tv_episodes_search(title, no_prompt = 0, show = nil, tvdb_id = '')
    cache_name, episodes = title.to_s + tvdb_id.to_s, []
    Utils.lock_block("#{__method__}#{cache_name}") do
      cached = Cache.cache_get('tv_episodes_search', cache_name, 1)
      return cached if cached
      title, show = tv_show_search(title, no_prompt) unless show
      unless show.nil?
        $speaker.speak_up("Using #{title} as series name", 0)
        episodes = $tvdb.get_all_episodes(show)
        episodes.map! {|e| Episode.new(Cache.object_pack(e, 1))}
      end
      Cache.cache_add('tv_episodes_search', cache_name, [show, episodes], show)
    end
    return show, episodes
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding), 0)
    Cache.cache_add('tv_episodes_search', cache_name, [nil, []], nil)
    return nil, []
  end

  def self.tv_show_get(tvdb_id)
    cached = Cache.cache_get('tv_show_get', tvdb_id.to_s)
    return cached if cached
    show = $tvdb.get_series_by_id(tvdb_id)
    show = TVMaze::Show.lookup({'thetvdb' => tvdb_id.to_i}) if show.nil?
    show = TvSeries.new(Cache.object_pack(show, 1))
    title = show.name
    Cache.cache_add('tv_show_get', tvdb_id.to_s, [title, show], show)
    return title, show
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    Cache.cache_add('tv_show_get', tvdb_id.to_s, ['', nil], nil)
    return '', nil
  end

  def self.tv_show_search(title, no_prompt = 0, ids = {}, original_filename = '')
    title = StringUtils.prepare_str_search(title)
    cache_name = title.to_s + ids['tvdb'].to_s
    exact_title, show = title, nil
    Utils.lock_block("#{__method__}_#{title}#{ids}") {
      cached = Cache.cache_get('tv_show_search', cache_name)
      return cached if cached
      if ids['tvdb'].to_i > 0
        exact_title, show = tv_show_get(ids['tvdb'])
        Cache.cache_add('tv_show_search', cache_name, [exact_title, show], show)
        return exact_title, show unless show.nil?
      end
      tvdb_shows = $tvdb.search(title)
      tvdb_shows = $tvdb.search(title.gsub(/ \(\d{4}\)$/, '')) if tvdb_shows.empty?
      tvdb_shows = TVMaze::Show.search(title).map {|s| Cache.object_pack(s, 1)} if tvdb_shows.empty?
      tvdb_shows = TVMaze::Show.search(title.gsub(/ \(\d{4}\)$/, '')).map {|s| Cache.object_pack(s, 1)} if tvdb_shows.empty?
      tvdb_shows.map! {|s| s = Cache.object_pack(TvSeries.new(s), 1); s['first_aired'] = identify_release_year(s['name']).to_s; s}
      exact_title, show = media_chose(title, tvdb_shows, {'name' => 'name', 'url' => 'url', 'year' => 'first_aired'}, 'shows', no_prompt)
      exact_title, show = tv_show_get(show['tvdb_id']) if show
      if show.nil? && original_filename.to_s != ''
        exact_title, show = Kodi.kodi_lookup('episode', original_filename, exact_title)
      end
      Cache.cache_add('tv_show_search', cache_name, [exact_title, show], show)
    }
    return exact_title, show
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding), 0)
    Cache.cache_add('tv_show_search', cache_name, [title, nil], nil)
    return title, nil
  end
end
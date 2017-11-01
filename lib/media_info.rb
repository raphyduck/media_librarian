class MediaInfo

  @last_tvmaze_req = Time.now - 1.day
  @tv_episodes = {}
  @media_folders = {}
  @cached_tvdb_search = {}

  def self.clean_title(title)
    title.gsub(/\(I+\) /, '').gsub(' (Video)', '').gsub(/\(TV .+\)/, '') rescue title
  end

  def self.filter_quality(filename, min_quality = '', max_quality = '')
    ['RESOLUTIONS', 'SOURCES', 'CODECS', 'AUDIO'].each do |t|
      file_q = (filename.downcase.gsub('-', '').scan(REGEX_QUALITIES).flatten & eval(t))[0].to_s
      min_quality.to_s.split(' ').each do |q|
        return false if eval(t).include?(q) && (file_q.empty? || eval(t).index(q) < eval(t).index(file_q))
      end
      max_quality.to_s.split(' ').each do |q|
        return false if eval(t).include?(q) && eval(t).index(q) > eval(t).index(file_q)
      end
    end
    true
  end

  def self.identify_metadata(filename, type, item_name = '', item = nil, no_prompt = 0, folder_hierarchy = {})
    metadata = {}
    ep_filename = File.basename(filename)
    item_name, item = identify_title(filename, type, no_prompt, (folder_hierarchy[type] || FOLDER_HIERARCHY[type])) if item_name.to_s == '' || item.nil?
    return metadata if item.nil? && no_prompt.to_i > 0
    metadata['quality'] = metadata['quality'] || File.basename(ep_filename).downcase.gsub('-', '').scan(REGEX_QUALITIES).join('.').gsub('-', '')
    metadata['proper'], _ = identify_proper(ep_filename)
    metadata['extension'] = ep_filename.gsub(/.*\.(\w{2,4}$)/, '\1')
    case type
      when 'shows'
        metadata['episode_season'], ep_nb = identify_tv_episodes_numbering(ep_filename)
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
    p = File.basename(filename).downcase.match(/[\. ](proper|repack|real)[\. ]/).to_s.gsub(/[\. ]/, '').gsub(/(repack|real)/), 'proper')
    return p, (p != '' ? 1 : 0)
  end

  def self.identify_title(filename, type, no_prompt = 0, folder_level = 2)
    in_path = Utils.is_in_path(@media_folders.map { |k, _| k }, filename)
    return @media_folders[in_path] if in_path && !@media_folders[in_path].nil?
    title, item = nil, nil
    filename, i_folder = Utils.get_only_folder_levels(filename, folder_level.to_i)
    r_folder = filename
    while item.nil?
      t_folder, r_folder = Utils.get_top_folder(r_folder)
      case type
        when 'movies'
          title, item = movie_lookup(t_folder, no_prompt)
        when 'shows'
          title, item = tv_show_search(t_folder, no_prompt)
        else
          title = File.basename(filename).downcase.gsub(REGEX_QUALITIES, '').gsub(/\.{\w{2,4}$/, '')
      end
      break if t_folder == r_folder
    end
    @media_folders[i_folder + filename.gsub(r_folder, '')] = [title, item] unless @media_folders[i_folder + filename.gsub(r_folder, '')]
    return title, item
  end

  def self.identify_tv_episodes_numbering(filename)
    identifiers = File.basename(filename).downcase.scan(/(^|[s\. _\^\[])(\d{1,3}[ex]\d{1,4}(\.\d[\. ])?)[\&-]?([ex]\d{1,2}(\.\d[\. ])?)?/)
    identifiers = File.basename(filename).scan(/(^|[\. _\[])(\d{3,4})[\. _]/) if identifiers.empty?
    season, ep_nb = '', []
    unless identifiers.first.nil?
      identifiers.each do |m|
        part, part2 = 0, 0
        bd = m[1].to_s.scan(/^(\d{1,3})[ex]/)
        nb2 = 0
        if bd.first.nil? && m[1].to_s.match(/^\d/)
          case m[1].to_s.length
            when 3
              season = m[1].to_s.gsub(/^(\d)\d+/, '\1') if season == ''
              nb = m[1].gsub(/^\d(\d+)/, '\1').to_i
            when 4
              season = m[1].to_s.gsub(/^(\d{2})\d+/, '\1') if season == ''
              nb = m[1].gsub(/^\d{2}(\d+)/, '\1').to_i
            else
              nb = 0
          end
        else
          season = bd.first[0].to_s.to_i if season == ''
          nb = m[1].gsub(/\d{1,3}[ex](\d{1,4})/, '\1')
          nb2 = m[3].gsub(/[ex](\d{1,4})/, '\1') if m[3].to_s != ''
        end
        part = m[2].to_s.gsub('.', '').to_i
        part2 = m[4].to_s.gsub('.', '').to_i
        ep_nb << {:ep => nb.to_i, :part => part.to_i} if nb.to_i > 0 && ep_nb.select { |x| x == nb.to_i }.empty?
        ep_nb << {:ep => nb2.to_i, :part => part2.to_i} if nb2.to_i > 0 && ep_nb.select { |x| x == nb2.to_i }.empty?
      end
    end
    return season, ep_nb
  end

  def self.media_qualities(filename)
    {
        'resolutions' => filename.downcase.match(Regexp.new('[ \.\(\)\-](' + RESOLUTIONS.join('|') + ')')).to_s.gsub(/[ \.\(\)\-]/, '').to_s,
        'sources' => filename.downcase.match(Regexp.new('[ \.\(\)\-](' + SOURCES.join('|') + ')')).to_s.gsub(/[ \.\(\)\-]/, '').to_s,
        'codecs' => filename.downcase.match(Regexp.new('[ \.\(\)\-](' + CODECS.join('|') + ')')).to_s.gsub(/[ \.\(\)\-]/, '').to_s,
        'audio' => filename.downcase.match(Regexp.new('[ \.\(\)\-](' + AUDIO.join('|') + ')')).to_s.gsub(/[ \.\(\)\-]/, '').to_s,
        'proper' => identify_proper(filename)[1]
    }
  end

  def self.movie_lookup(title, no_prompt = 0, search_alt = 0)
    movies = moviedb_search(title)
    movie = nil
    unless movies.empty?
      results = movies.map { |m| [clean_title(m.title), m.url] }
      results += [['Edit title manually', ''], ['Skip file', '']]
      loop do
        choice = search_alt
        if search_alt > 0 && $speaker.ask_if_needed("Look for alternative titles for this file? (y/n)'", no_prompt, 'n') == 'y'
          $speaker.speak_up("Alternatives titles found:")
          results.each_with_index do |m, idx|
            $speaker.speak_up("#{idx + 1}: #{m[0]}#{' (info IMDB: ' + URI.escape(m[1]) + ')' if m[1].to_s != ''}")
          end
          choice = $speaker.ask_if_needed("Enter the number of the chosen title: ", no_prompt, 1).to_i - 1
          next if choice < 0 || choice > results.count
        end
        t = results[choice]
        break if t[0] == 'Skip file'
        if t[0] == 'Edit title manually'
          $speaker.speak_up('Enter the title to look for:')
          title = STDIN.gets.strip
          break
        end
        movie = movies[choice]
        title = movie.title
        break
      end
    end
    return title, movie
  rescue => e
    $speaker.tell_error(e, "MediaInfo.movie_title_lookup")
    return title, nil
  end

  def self.movie_title_lookup(title, first_only = false)
    movies = moviedb_search(title)
    found = false
    if movies.empty?
      results = [[title, '']]
    else
      results = movies.map { |m| [clean_title(m.title), m.url] }
      found = true
    end
    return (first_only ? results.first : results), found
  rescue => e
    $speaker.tell_error(e, "MediaInfo.movie_title_lookup")
    return (first_only ? [title, ''] : [[title, '']]), false
  end

  def self.moviedb_search(title, no_output = false)
    results = []
    movies = Imdb::Search.new(title).movies
    movies.each do |m|
      results << m unless (m.title.match(/\(TV .+\)/) && !m.title.match(/\(TV Movie\)/)) || m.title.match(/ \(Short\)/)
    end
    return results
  rescue => e
    $speaker.tell_error(e, "MediaInfo.moviedb_search")
    return []
  end

  def self.media_add(item_name, type, full_name, identifier, attrs = {}, file = '', files = {})
    return files if file != '' && files[:files] && files[:files][file].to_s == file
    files[identifier] = [] if files[identifier].nil?
    files[identifier] << {:type => type, :name => item_name, :full_name => full_name, :identifier => identifier, :file => file}.merge(attrs)
    if file.to_s != ''
      files[:files] = {} if files[:files].nil?
      files[:files][file] = {:type => type, :name => item_name, :full_name => full_name, :identifier => identifier, :file => file}.merge(attrs)
    end
    if attrs[:show]
      files[:shows] = {}
      files[:shows][item_name] = attrs[:show]
    end
    files
  end

  def self.media_exist?(files, identifier)
    files.each do |id, _|
      return true if id.to_s.include?(identifier)
    end
    false
  end

  def self.media_get(files, identifier)
    eps = nil
    eps = files.select { |k, _| k.to_s.include?(identifier) }.map { |_, v| v }.flatten if media_exist?(files, identifier)
    eps
  end

  def self.sort_media_files(files, qualities = {})
    sorted, r = [], []
    files.each do |f|
      qs = MediaInfo.media_qualities(File.basename(f[:file]))
      if qualities.nil? || qualities.empty? || filter_quality(f[:file], qualities['min_quality'], qualities['max_quality'])
        sorted << [f[:file], qs['resolutions'], qs['sources'], qs['codecs'], qs['audio'], qs['proper']]
        r << f
      end
    end
    sorted.sort_by! { |x| (AUDIO.index(x[4]) || 999).to_i }
    sorted.sort_by! { |x| (CODECS.index(x[3]) || 999).to_i }
    sorted.sort_by! { |x| (SOURCES.index(x[2]) || 999).to_i }
    sorted.sort_by! { |x| (RESOLUTIONS.index(x[1]) || 999).to_i }
    sorted.sort_by! { |x| -x[5].to_i }
    r.sort_by! { |x| sorted.map { |x| x[0] }.index(x[:file]) }
  end

  def self.tv_series_search(title, tvdb_id = '')
    while Time.now - @last_tvmaze_req < 1
      sleep 1
    end
    res = nil
    if tvdb_id.to_i > 0
      begin
        res = TVMaze::Show.lookup({'thetvdb' => tvdb_id.to_i})
      rescue => e
        $speaker.tell_error(e, "tvmaze::show.lookup")
      end
    end
    res = TVMaze::Show.search(title).first if res.nil?
    @last_tvmaze_req = Time.now
    return res, !res.nil?
  rescue => e
    $speaker.tell_error(e, "MediaInfo.tv_series_search")
    return nil, false
  end

  def self.tv_episodes_search(title, no_prompt = 0, show = nil)
    title, show = tv_show_search(title, no_prompt) unless show
    episodes = []
    unless show.nil?
      $speaker.speak_up("Using #{title} as series name", 0)
      episodes = $tvdb.get_all_episodes(show)
    end
    return show, episodes
  rescue => e
    $speaker.tell_error(e, "MediaInfo.tv_episodes_search")
    return nil, []
  end

  def self.tv_show_search(title, no_prompt = 0)
    go_on = 0
    return @cached_tvdb_search[title] if @cached_tvdb_search[title]
    title, show = title, nil
    year = title.match(/\((\d{4})\)$/)[1].to_i rescue 0
    tvdb_shows = $tvdb.search(title)
    tvdb_shows = $tvdb.search(title.gsub(/ \(\d{4}\)$/, '')) if tvdb_shows.empty?
    while go_on.to_i == 0
      tvdb_show = tvdb_shows.shift
      break if tvdb_show.nil?
      next if year.to_i > 0 && tvdb_show['FirstAired'] &&
          tvdb_show['FirstAired'].match(/\d{4}/) &&
          tvdb_show['FirstAired'].match(/\d{4}/).to_s.to_i > 0 &&
          (tvdb_show['FirstAired'].match(/\d{4}/).to_s.to_i > year + 1 || tvdb_show['FirstAired'].match(/\d{4}/).to_s.to_i < year - 1)
      if tvdb_show['SeriesName'].downcase.gsub(/[ \(\)\.\:,]/, '') == title.downcase.gsub(/[ \(\)\.\:,]/, '')
        go_on = 1
      else
        go_on = $speaker.ask_if_needed("Found TVDB name #{tvdb_show['SeriesName']} for folder #{title}, proceed with that? (y/n)", no_prompt, 'n') == 'y' ? 1 : 0
      end
      if tvdb_show && go_on.to_i > 0
        show = TvdbParty::Series.new($tvdb, tvdb_show)
        @cached_tvdb_search[title] = [show.name, show]
        title = show.name
      end
    end
    return title, show
  rescue => e
    $speaker.tell_error(e, "MediaInfo.tv_episodes_search")
    return title, nil
  end
end
class MediaInfo

  @last_tvmaze_req = Time.now - 1.day

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

  def self.identify_proper(filename)
    p = File.basename(filename).downcase.match(/[\. ](proper|repack)[\. ]/).to_s.gsub(/[\. ]/, '').gsub('repack', 'proper')
    return p, (p != '' ? 1 : 0)
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

  def self.series_add(series_name, season, episode, part, file = '', series = {})
    series[:name] = series_name
    series[season.to_i] = {} if series[season.to_i].nil?
    series[season.to_i][episode.to_i] = {} if series[season.to_i][episode.to_i].nil?
    series[season.to_i][episode.to_i][part.to_i] = [] if series[season.to_i][episode.to_i][part.to_i].nil?
    series[season.to_i][episode.to_i][part.to_i] << {:name => series_name, :season => season.to_i, :episode => episode.to_i, :part => part.to_i, :file => file}
    series
  end

  def self.series_exist?(series, series_name, season, episode)
    return series[:name] == series_name && !series[season.to_i].nil? && !series[season.to_i][episode.to_i].nil? && !series[season.to_i][episode.to_i].empty?
  end

  def self.series_get_ep(series, series_name, season, episode, part)
    ep = nil
    ep = series[season.to_i][episode.to_i][part.to_i] if series_exist?(series, series_name, season, episode)
    ep
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
    r.sort_by!{ |x| sorted.map{|x| x[0]}.index(x[:file])}
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

  def self.tv_episodes_search(title, no_prompt = 0)
    go_on = 0
    show, episodes = nil, []
    year = title.match(/\((\d{4})\)$/)[1].to_i rescue 0
    tvdb_shows = $tvdb.search(title)
    tvdb_shows = $tvdb.search(title.gsub(/ \(\d{4}\)$/, '')) if tvdb_shows.empty?
    while go_on.to_i == 0
      tvdb_show = tvdb_shows.shift
      break if tvdb_show.nil?
      next if year > 0 && tvdb_show['FirstAired'] &&
          tvdb_show['FirstAired'].match(/\d{4}/) &&
          tvdb_show['FirstAired'].match(/\d{4}/).to_s.to_i > 0  &&
          (tvdb_show['FirstAired'].match(/\d{4}/).to_s.to_i > year + 1 || tvdb_show['FirstAired'].match(/\d{4}/).to_s.to_i < year - 1)
      if tvdb_show['SeriesName'].downcase.gsub(/[ \(\)\.\:]/, '') == title.downcase.gsub(/[ \(\)\.\:]/, '')
        go_on = 1
      else
        go_on = $speaker.ask_if_needed("Found TVDB name #{tvdb_show['SeriesName']} for folder #{title}, proceed with that? (y/n)", no_prompt, 'y') == 'y' ? 1 : 0
      end
    end
    unless go_on == 0 || tvdb_show.nil?
      $speaker.speak_up("Using #{tvdb_show['SeriesName']} as series name", 0)
      show = $tvdb.get_series_by_id(tvdb_show['seriesid'])
      episodes = $tvdb.get_all_episodes(show)
    end
    return show, episodes
  rescue => e
    $speaker.tell_error(e, "MediaInfo.tv_episodes_search")
    return nil, []
  end
end
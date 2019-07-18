class TvSeries
  attr_accessor :id, :tvdb_id, :name, :overview, :seasons, :first_aired, :genres, :network, :rating, :rating_count, :runtime,
                :actors, :banners, :air_time, :imdb_id, :content_rating, :status, :url, :language, :aired_episodes, :data_source

  def initialize(options = {})
    @tvdb_id = (options['ids'] || {})['thetvdb'] || (options['ids'] || {})['tvdb'] || options['seriesid'] || options['id']
    @id = @tvdb_id
    @language = options['language']
    @name = options["name"] || options['SeriesName'] || options['title']
    @overview = options["overview"] || options['Overview'] || options['summary']
    @network = options["network"] || options['Network']
    @runtime = options["runtime"]
    @air_time = options['air_time']
    @imdb_id = options["imdb_id"] || options['IMDB_ID'] || options['ids']['imdb'] rescue nil
    @content_rating = options["content_rating"] || options['certification']
    @status = options["status"]
    @genres = options["genres"]
    @rating = options["rating"]
    @rating_count = options["rating_count"] || options['votes']
    @first_aired = options["first_aired"] || options['FirstAired'] || options['premiered']
    @url = options['url']
    @aired_episodes = options['aired_episodes']
    @data_source = options['data_source']
  end

  def anthology?
    @overview.downcase.include?('anthology')
  end

  def formal_status
    fs = @status.dup
    {'canceled' => 'ended', 'returning series'=> 'continuing'}.each {|k, v| fs[k] &&= v}
    fs.downcase
  rescue
    fs
  end

  def self.ep_name_to_season(name)
    name.gsub(/(S\d{1,3})E\d{1,4}/, '\1')
  end

  def self.identifier(series_name, season, episode)
    "tv#{series_name}S#{format('%03d', season.to_i)}#{'E' + format('%03d', episode.to_i).to_s if episode.to_i > 0}"
  end

  def self.identify_tv_episodes_numbering(filename)
    identifiers = File.basename(filename).scan(Regexp.new("(?=(#{REGEX_TV_EP_NB}))"))
    season, seasonp, ep_nb, ep_nb_single = [], [], [], []
    identifiers.each do |m|
      s = ''
      s = m[17] if m[17]
      if m[20]
        case m[20].to_s.length
        when 3
          m_s = /^(\d)(\d+)/
        when 4
          m_s = /^(\d{2})(\d+)/
        end
        sp = m[20].to_s.gsub(m_s, '\1')
        ep_nb_single << {:s => sp, :ep => m[20].gsub(m_s, '\2').to_i, :part => 0}
        seasonp << sp unless seasonp.include?(sp)
      else
        s = m[4] if s == '' && m[4]
        (0..2).each do |i|
          ep_nb << {:s => s, :ep => m[5 + i * 4].to_i, :part => m[7 + i * 4].to_i} if m[5 + i * 4]
        end
      end
      season << s unless season.include?(s) || s == ''
    end
    ep_nb = ep_nb_single.uniq if ep_nb.empty?
    season = seasonp if season.empty?
    season = (season[0]..season[1]).to_a if ep_nb.empty? && season.count == 2
    ep_ids = (ep_nb.empty? ? season.map {|s| {:s => s}} : ep_nb.uniq).map {|e| "S#{format('%02d', e[:s].to_i)}#{'E' + format('%02d', e[:ep].to_i) if e[:ep].to_s != ''}"}
    return season, ep_nb.uniq, ep_ids
  end

  def self.identify_file_type(filename, nbs = nil, seasons = nil)
    f_type = 'episode'
    seasons, nbs, _ = TvSeries.identify_tv_episodes_numbering(filename) unless nbs && seasons
    if nbs.empty?
      f_type = seasons.empty? ? 'series' : 'season'
    end
    f_type
  end

  def self.list_missing_episodes(episodes_in_files, qualifying_files, no_prompt = 0, delta = 10, include_specials = 0, qualities = {})
    $speaker.speak_up "Will parse TV Shows for missing episodes released more than #{delta} days ago, #{'NOT ' if include_specials.to_i == 0} including specials..." if Env.debug?
    tv_episodes, tv_seasons, missing_eps = {}, {}, {}
    episodes_in_files[:shows].sort_by {|series_name, _| series_name}.each do |series_name, show|
      _, tv_episodes[series_name] = TvSeries.tv_episodes_search(series_name, no_prompt, show)
      tv_seasons[series_name] = {} if tv_seasons[series_name].nil?
      existing_season_eps, qualifying_season_eps, last_season = {}, {}, nil
      tv_episodes[series_name].sort_by {|e| (e.air_date || Time.now + 6.months)}.reverse.each do |ep|
        is_new_season = (last_season != ep.season_number.to_i)
        last_season = ep.season_number.to_i
        next unless (ep.air_date.to_s != '' && ep.air_date < Time.now - delta.to_i.days) ||
            (ep.air_date.to_s == '' && MediaInfo.media_exist?(episodes_in_files, identifier(series_name, ep.season_number, ep.number.to_i + 1)))
        next if include_specials.to_i == 0 && ep.season_number.to_i == 0
        full_name, identifiers, info, ep_nb = '', '', {}, 0
        if existing_season_eps[ep.season_number].nil?
          existing_season_eps[ep.season_number] = MediaInfo.media_get(episodes_in_files, identifier(series_name, ep.season_number, 0))
          qualifying_season_eps[ep.season_number] = if qualities.to_s == ''
                                                      existing_season_eps[ep.season_number]
                                                    else
                                                      MediaInfo.media_get(qualifying_files, identifier(series_name, ep.season_number, 0))
                                                    end
        end
        if tv_seasons[series_name][ep.season_number.to_i].nil? && (is_new_season || ep.air_date.nil? || ep.air_date < Time.now - 6.months) && qualifying_season_eps[ep.season_number].empty?
          tv_seasons[series_name][ep.season_number.to_i] = 1
          full_name = "#{series_name} S#{format('%02d', ep.season_number.to_i)}"
          full_name, identifiers, info = MediaInfo.parse_media_filename(full_name, 'shows', show, series_name, no_prompt)
          info.merge!({:files => existing_season_eps[ep.season_number].map {|_, f| f[:files]}.flatten})
        elsif tv_seasons[series_name][ep.season_number.to_i].nil? &&
            !MediaInfo.media_exist?(qualifying_season_eps[ep.season_number], identifier(series_name, ep.season_number, ep.number.to_i))
          full_name = "#{series_name} S#{format('%02d', ep.season_number.to_i)}E#{format('%02d', ep.number.to_i)}"
          full_name, identifiers, info = MediaInfo.parse_media_filename(full_name, 'shows', show, series_name, no_prompt)
          info.merge!({:existing_season_eps => existing_season_eps[ep.season_number].map {|_, f| f[:files]}.flatten})
          ep_nb = ep.number.to_i
          info.merge!({:files => MediaInfo.media_get(
              existing_season_eps[ep.season_number],
              identifier(series_name, ep.season_number, ep.number.to_i)
          ).map {|_, f| f[:files]}.flatten})
        end
        missing_eps = MediaInfo.missing_media_add(
            missing_eps,
            'shows',
            full_name,
            ep.air_date,
            series_name,
            identifiers,
            info,
            "#{full_name}#{' - ' + ep.name.to_s if ep_nb.to_i > 0}"
        )
      end
    end
    missing_eps
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

  def self.tv_show_get(ids, force_refresh = 0)
    cache_name = ids.map {|k, v| k.to_s + v.to_s if v.to_s != ''}.join
    cached = Cache.cache_get('tv_show_get', cache_name, nil, force_refresh)
    return cached if cached
    show, src = TraktAgent.show__summary(ids['trakt'] || ids['imdb'], '?extended=full'), 'trakt' if (ids['trakt'] || ids['imdb']).to_s != ''
    show, src = $tvdb.get_series_by_id(ids['tvdb']), 'tvdb' if show.nil?
    show, src = TVMaze::Show.lookup({'thetvdb' => ids['tvdb'].to_i}), 'tvmaze' if show.nil?
    show = TvSeries.new(Cache.object_pack(show, 1).merge({'@data_source' => src}))
    title = show.name
    Cache.cache_add('tv_show_get', cache_name, [title, show], show)
    return title, show
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    Cache.cache_add('tv_show_get', cache_name, ['', nil], nil)
    return '', nil
  end
end
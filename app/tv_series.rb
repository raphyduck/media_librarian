class TvSeries
  attr_accessor :id, :ids, :name, :overview, :seasons, :first_aired, :genres, :network, :rating, :rating_count, :runtime,
                :actors, :banners, :air_time, :content_rating, :status, :url, :language, :aired_episodes, :data_source, :year

  def initialize(options = {})
    @ids = TvSeries.formate_ids(options['ids'] || {'thetvdb' => options['seriesid'], 'imdb' => options["imdb_id"] || options['IMDB_ID']})
    @ids[options['data_source']] = options['id'] if options['data_source'].to_s != '' && @ids[options['data_source']].to_s == ''
    @id = @ids['thetvdb'] #@id is used to fetch episodes
    @language = Languages.get_code(options['language'].to_s != '' ? options['language'].to_s : options['country'])
    @name = options["name"] || options['SeriesName'] || options['title']
    @overview = options["overview"] || options['Overview'] || options['summary']
    @network = options["network"] || options['Network']
    @runtime = options["runtime"]
    @air_time = options['air_time']
    @content_rating = options["content_rating"] || options['certification']
    @status = options["status"]
    @genres = options["genres"]
    @rating = options["rating"]
    @rating_count = options["rating_count"] || options['votes']
    @first_aired = options["first_aired"] || options['FirstAired'] || options['premiered']
    @url = options['url']
    @aired_episodes = options['aired_episodes']
    @data_source = options['data_source']
    @name = "#{Metadata.detect_real_title(@name, 'shows', 0, 0)} (#{year})"
    @year = year
  end

  def anthology?
    @overview.downcase.include?('anthology')
  end

  def formal_status
    fs = @status.dup
    {'canceled' => 'ended', 'returning series' => 'continuing'}.each { |k, v| fs[k] &&= v }
    fs.downcase
  rescue
    fs
  end

  def year
    return @year if @year
    @year = DateTime.parse(@first_aired).year rescue 0
  end

  def self.ep_name_to_season(name)
    name.gsub(/(S\d{1,3})E\d{1,4}/, '\1')
  end

  def self.formate_ids(ids)
    ids.transform_keys { |k| k.sub(/^tvdb$/, 'thetvdb') }
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
    ep_ids = (ep_nb.empty? ? season.map { |s| {:s => s} } : ep_nb.uniq).map { |e| "S#{format('%02d', e[:s].to_i)}#{'E' + format('%02d', e[:ep].to_i) if e[:ep].to_s != ''}" }
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
    tv_episodes, tv_seasons, missing_eps, incomplete_seasons = {}, {}, {}, {}
    episodes_in_files[:shows].sort_by { |series_name, _| series_name }.each do |series_name, show|
      _, tv_episodes[series_name] = TvSeries.tv_episodes_search(series_name, no_prompt, show)
      tv_seasons[series_name] = {} if tv_seasons[series_name].nil?
      incomplete_seasons[series_name] = {} if incomplete_seasons[series_name].nil?
      existing_season_eps, qualifying_season_eps, last_season = {}, {}, nil
      tv_episodes[series_name].sort_by { |e| (e.air_date || Time.now + 6.months) }.reverse.each do |ep|
        is_new_season = (last_season != ep.season_number.to_i)
        last_season = ep.season_number.to_i
        next if tv_seasons[series_name][ep.season_number.to_i].to_i == 1
        next unless (ep.air_date.to_s != '' && ep.air_date < Time.now - delta.to_i.days) ||
            (ep.air_date.to_s == '' && Metadata.media_exist?(episodes_in_files, identifier(series_name, ep.season_number, ep.number.to_i + 1)))
        next if include_specials.to_i == 0 && ep.season_number.to_i == 0
        full_name, identifiers, info, ep_nb = '', '', {}, 0
        if existing_season_eps[ep.season_number].nil?
          existing_season_eps[ep.season_number] = Metadata.media_get(episodes_in_files, identifier(series_name, ep.season_number, 0))
          qualifying_season_eps[ep.season_number] = if qualities.to_s == ''
                                                      existing_season_eps[ep.season_number]
                                                    else
                                                      Metadata.media_get(qualifying_files, identifier(series_name, ep.season_number, 0))
                                                    end
        end
        incomplete_seasons[series_name][ep.season_number.to_i] = 0 if incomplete_seasons[series_name][ep.season_number.to_i].nil?
        if incomplete_seasons[series_name][ep.season_number.to_i].to_i == 0
          incomplete_seasons[series_name][ep.season_number.to_i] = Metadata.media_exist?(existing_season_eps[ep.season_number], identifier(series_name, ep.season_number, ep.number.to_i)) ? 0 : 1
        end
        if tv_seasons[series_name][ep.season_number.to_i].nil? && (is_new_season || ep.air_date.nil? || ep.air_date < Time.now - 6.months) && qualifying_season_eps[ep.season_number].empty?
          tv_seasons[series_name][ep.season_number.to_i] = 1
          full_name = "#{series_name} S#{format('%02d', ep.season_number.to_i)}"
          full_name, identifiers, info = Metadata.parse_media_filename(full_name, 'shows', show, series_name, no_prompt)
          info.merge!({:files => existing_season_eps[ep.season_number].map { |_, f| f[:files] }.flatten, :season_incomplete => incomplete_seasons[series_name]})
        elsif tv_seasons[series_name][ep.season_number.to_i].nil? &&
            !Metadata.media_exist?(qualifying_season_eps[ep.season_number], identifier(series_name, ep.season_number, ep.number.to_i))
          full_name = "#{series_name} S#{format('%02d', ep.season_number.to_i)}E#{format('%02d', ep.number.to_i)}"
          full_name, identifiers, info = Metadata.parse_media_filename(full_name, 'shows', show, series_name, no_prompt)
          info.merge!({:existing_season_eps => existing_season_eps[ep.season_number].map { |_, f| f[:files] }.flatten, :season_incomplete => incomplete_seasons[series_name]})
          ep_nb = ep.number.to_i
          info.merge!({:files => Metadata.media_get(
              existing_season_eps[ep.season_number],
              identifier(series_name, ep.season_number, ep.number.to_i)
          ).map { |_, f| f[:files] }.flatten})
        end
        missing_eps = Metadata.missing_media_add(
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

  def self.tv_episodes_search(title, no_prompt = 0, show = nil)
    cache_name, episodes = title.to_s + (show.id rescue '').to_s, []
    Utils.lock_block("#{__method__}#{cache_name}") do
      cached = Cache.cache_get('tv_episodes_search', cache_name, 1)
      return cached if cached
      title, show = tv_show_search(title, no_prompt) unless show
      return show, episodes if show.nil?
      $speaker.speak_up("Using #{title} as series name", 0)
      episodes = $tvdb.get_all_episodes(show)
      episodes.map! { |e| Episode.new(Cache.object_pack(e, 1)) }
      Cache.cache_add('tv_episodes_search', cache_name, [show, episodes], show)
    end
    return show, episodes
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding), 0)
    Cache.cache_add('tv_episodes_search', cache_name, [nil, []], nil)
    return nil, []
  end

  def self.tv_show_get(ids)
    cache_name = ids.map { |k, v| k.to_s + v.to_s if v.to_s != '' }.join
    return '', nil if cache_name == ''
    cached = Cache.cache_get('tv_show_get', cache_name, nil)
    return cached if cached
    show, src = Cache.object_pack(TraktAgent.show__summary(ids['trakt'] || ids['imdb'], '?extended=full'), 1), 'trakt' if (ids['trakt'] || ids['imdb']).to_s != ''
    show, src = Cache.object_pack((TVMaze::Show.lookup(ids) rescue nil), 1), 'tvmaze' if (show.to_s == '' || (show['title'].to_s == '' && show['SeriesName'].to_s == '' && show['name'].to_s == '') || (show["first_aired"].to_s == '' || show['FirstAired'].to_s == '' || show['premiered'].to_s == '')) && !ids.empty?
    show, src = Cache.object_pack($tvdb.get_series_by_id(ids['thetvdb']), 1), 'thetvdb' if (show.to_s == '' || (show['title'].to_s == '' && show['SeriesName'].to_s == '' && show['name'].to_s == '')) && ids['thetvdb'].to_s != ''
    show = show && (show['title'].to_s != '' || show['SeriesName'].to_s != '' || show['name'].to_s != '') ? TvSeries.new(show.merge({'data_source' => src})) : nil
    title = if show
              ids['force_title'].to_s != '' ? ids['force_title'] : show.name #We need to bypass name given by some providers which doesn't match the real name of the show...
            else
              ''
            end
    Cache.cache_add('tv_show_get', cache_name, [title, show], show)
    $speaker.speak_up "#{Utils.arguments_dump(binding)}= '', nil" if show.nil?
    return title, show
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    Cache.cache_add('tv_show_get', cache_name, ['', nil], nil)
    return '', nil
  end

  def self.tv_show_search(title, no_prompt = 0, original_filename = '', ids = {})
    Metadata.media_lookup('shows', title, 'tv_show_search', {'name' => 'name', 'url' => 'url', 'year' => 'year'}, TvSeries.method('tv_show_get'),
                          [[TVMaze::Show, 'search'], [$tvdb, 'search']], no_prompt, original_filename, TvSeries.formate_ids(ids))
  end
end
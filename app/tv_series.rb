class TvSeries
  attr_accessor :id, :tvdb_id, :name, :overview, :seasons, :first_aired, :genres, :network, :rating, :rating_count, :runtime,
                :actors, :banners, :air_time, :imdb_id, :content_rating, :status, :url, :language

  @missing_episodes = Vash.new

  def initialize(options={})
    @tvdb_id = (options['ids'] || {})['thetvdb'] || options['seriesid'] || options['id']
    @id = @tvdb_id
    @language = options['language']
    @name = options["name"] || options['SeriesName']
    @overview = options["overview"] || options['Overview']
    @network = options["network"] || options['Network']
    @runtime = options["runtime"]
    @air_time = options['air_time']
    @imdb_id = options["imdb_id"] || options['IMDB_ID']
    @content_rating = options["content_rating"]
    @status = options["status"]
    @genres = options["genres"]
    @rating = options["rating"]
    @rating_count = options["rating_count"]
    @first_aired = options["first_aired"] || options['FirstAired'] || options['premiered']
    @url = options['url']
  end

  def self.ep_name_to_season(name)
    name.gsub(/(S\d{1,3})E\d{1,4}/, '\1')
  end

  def self.identifier(series_name, season, episode)
    "tv#{series_name}S#{season.to_i}#{'E' + episode.to_i.to_s if episode.to_i > 0}"
  end

  def self.identifier_season(series_name, season)
    "tv#{series_name}S#{season.to_i}"
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
          ep_nb << {:s => s, :ep => m[5+i*4].to_i, :part => m[7+i*4].to_i} if m[5+i*4]
        end
      end
      season << s unless season.include?(s) || s == ''
    end
    ep_nb = ep_nb_single.uniq if ep_nb.empty?
    season = seasonp if season.empty?
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

  def self.list_missing_episodes(episodes_in_files, no_prompt = 0, delta = 10, include_specials = 0, missing_eps = {})
    tv_episodes, tv_seasons, cache_name, = {}, {}, delta.to_s + include_specials.to_s + episodes_in_files[:shows].count.to_s
    Utils.lock_block(__method__.to_s + cache_name) {
      if @missing_episodes[cache_name].nil?
        @missing_episodes[cache_name] = {}
        return @missing_episodes[cache_name] if episodes_in_files[:shows].nil?
        episodes_in_files[:shows].each do |series_name, show|
          _, tv_episodes[series_name] = MediaInfo.tv_episodes_search(series_name, no_prompt, show)
          tv_seasons[series_name] = {} if tv_seasons[series_name].nil?
          existing_season_eps, last_season = {}, nil
          tv_episodes[series_name].sort_by { |e| (e.air_date || Time.now + 6.months) }.reverse.each do |ep|
            is_new_season = (last_season != ep.season_number.to_i)
            last_season = ep.season_number.to_i
            next unless (ep.air_date.to_s != '' && ep.air_date < Time.now - delta.to_i.days) ||
                (ep.air_date.to_s == '' && MediaInfo.media_exist?(episodes_in_files, identifier(series_name, ep.season_number, ep.number.to_i + 1)))
            next if include_specials.to_i == 0 && ep.season_number.to_i == 0
            full_name, identifiers, info, ep_nb = '', '', {}, 0
            if existing_season_eps[ep.season_number].nil?
              existing_season_eps[ep.season_number] = MediaInfo.media_get(episodes_in_files, identifier_season(series_name, ep.season_number))
            end
            if tv_seasons[series_name][ep.season_number.to_i].nil? && (is_new_season || ep.air_date.nil? || ep.air_date < Time.now - 6.months) && existing_season_eps[ep.season_number].empty?
              tv_seasons[series_name][ep.season_number.to_i] = 1
              full_name = "#{series_name} S#{format('%02d', ep.season_number.to_i)}"
              full_name, identifiers, info = MediaInfo.parse_media_filename(full_name, 'shows', show, series_name, no_prompt)
            elsif tv_seasons[series_name][ep.season_number.to_i].nil? &&
                !MediaInfo.media_exist?(existing_season_eps[ep.season_number], identifier(series_name, ep.season_number, ep.number.to_i))
              full_name = "#{series_name} S#{format('%02d', ep.season_number.to_i)}E#{format('%02d', ep.number.to_i)}"
              full_name, identifiers, info = MediaInfo.parse_media_filename(full_name, 'shows', show, series_name, no_prompt)
              info.merge!({:existing_season_eps => existing_season_eps[ep.season_number].map { |_, f| f[:files] }.flatten})
              ep_nb = ep.number.to_i
            end
            next if full_name == ''
            $speaker.speak_up("Missing #{full_name}#{' - ' + ep.name.to_s if ep_nb.to_i > 0} (aired on #{ep.air_date})", 0)
            @missing_episodes[cache_name, CACHING_TTL] = MediaInfo.media_add(series_name,
                                                                             'shows',
                                                                             full_name,
                                                                             identifiers,
                                                                             info,
                                                                             {},
                                                                             {},
                                                                             @missing_episodes[cache_name] || {}
            )
          end
        end
      end
    }
    @missing_episodes[cache_name].merge(missing_eps.reject { |k, _| k.is_a?(Symbol) })
  end
end
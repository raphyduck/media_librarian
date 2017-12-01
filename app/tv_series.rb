class TvSeries
  attr_accessor :id, :tvdb_id, :name, :overview, :seasons, :first_aired, :genres, :network, :rating, :rating_count, :runtime,
                :actors, :banners, :air_time, :imdb_id, :content_rating, :status, :url

  @missing_episodes = Vash.new

  def initialize(options={})
    @tvdb_id = options["id"] || options['seriesid']
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
    "tv#{series_name}S#{season.to_s}#{'E' + episode.to_s if episode.to_i > 0}"
  end

  def self.identifier_season(series_name, season)
    "tv#{series_name}S#{season.to_s}"
  end

  def self.identify_tv_episodes_numbering(filename)
    #TODO: Refactor this
    identifiers = File.basename(filename).downcase.scan(/(^|\/|[s\. _\^\[])(\d{1,3}[ex]\d{1,4}(\.\d[\. ])?)[\&-]?([ex]\d{1,2}(\.\d[\. ])?)?/)
    identifiers = File.basename(filename).downcase.scan(/(s\d{1,3}[\. ])/) if identifiers.empty?
    identifiers = File.basename(filename).scan(/(^|\/|[\. _\[])(\d{3,4})[\. _]/) if identifiers.empty?
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
          if m[0].to_s.match(/s\d{1,3}/)
            season = m[0].to_s.gsub(/s(\d{1,3})/, '\1').to_i if season == ''
          else
            season = bd.first[0].to_s.to_i if season == ''
            nb = m[1].gsub(/\d{1,3}[ex](\d{1,4})/, '\1')
            nb2 = m[3].gsub(/[ex](\d{1,4})/, '\1') if m[3].to_s != ''
          end
        end
        part = m[2].to_s.gsub('.', '').to_i
        part2 = m[4].to_s.gsub('.', '').to_i
        ep_nb << {:ep => nb.to_i, :part => part.to_i} if nb.to_i > 0 && ep_nb.select { |x| x == nb.to_i }.empty?
        ep_nb << {:ep => nb2.to_i, :part => part2.to_i} if nb2.to_i > 0 && ep_nb.select { |x| x == nb2.to_i }.empty?
      end
    end
    return season, ep_nb
  end

  def self.list_missing_episodes(episodes_in_files, no_prompt = 0, delta = 10, include_specials = 0, missing_eps = {})
    tv_episodes, tv_seasons, cache_name, = {}, {}, delta.to_s + include_specials.to_s
    Utils.lock_block(__method__.to_s + cache_name) {
      if @missing_episodes[cache_name].nil?
        @missing_episodes[cache_name] = {}
        return @missing_episodes[cache_name] if episodes_in_files[:shows].nil?
        episodes_in_files[:shows].each do |series_name, show|
          _, tv_episodes[series_name] = MediaInfo.tv_episodes_search(series_name, no_prompt, show)
          tv_seasons[series_name] = {} if tv_seasons[series_name].nil?
          tv_episodes[series_name].each do |ep|
            next unless (ep.air_date.to_s != '' && ep.air_date < Time.now - delta.to_i.days) ||
                (ep.air_date.to_s == '' && MediaInfo.media_exist?(episodes_in_files, identifier(series_name, ep.season_number, ep.number.to_i + 1)))
            next if include_specials.to_i == 0 && ep.season_number.to_i == 0
            full_name, identifiers, info, ep_nb = '', '', {}, 0
            existing_season_eps = MediaInfo.media_get(episodes_in_files, identifier_season(series_name, ep.season_number))
            if tv_seasons[series_name][ep.season_number.to_i].nil? && (ep.air_date.nil? || ep.air_date < Time.now - 6.months) && existing_season_eps.empty?
              tv_seasons[series_name][ep.season_number.to_i] = 1
              full_name = "#{series_name} S#{format('%02d', ep.season_number.to_i)}E#{format('%02d', 0)}"
              full_name, identifiers, info = MediaInfo.parse_media_filename(full_name, 'shows', show, series_name, no_prompt)
            elsif tv_seasons[series_name][ep.season_number.to_i].nil? &&
                !MediaInfo.media_exist?(existing_season_eps, identifier(series_name, ep.season_number, ep.number.to_i))
              full_name = "#{series_name} S#{format('%02d', ep.season_number.to_i)}E#{format('%02d', ep.number.to_i)}"
              full_name, identifiers, info = MediaInfo.parse_media_filename(full_name, 'shows', show, series_name, no_prompt)
              info.merge!({:existing_season_eps => existing_season_eps.map { |_, f| f[:files] }.flatten})
              ep_nb = ep.number.to_i
            end
            next if full_name == '' || Utils.entry_deja_vu?('download', identifier_season(series_name, ep.season_number)) ||
                Utils.entry_deja_vu?('download', identifier(series_name, ep.season_number, ep_nb))
            $speaker.speak_up("Missing #{full_name}#{' - ' + ep.name.to_s if ep_nb.to_i > 0} (aired on #{ep.air_date})", 0)
            @missing_episodes[cache_name, CACHING_TTL] = MediaInfo.media_add(series_name,
                                                                             'shows',
                                                                             full_name,
                                                                             identifiers,
                                                                             info,
                                                                             {},
                                                                             {},
                                                                             @missing_episodes[cache_name]
            )
          end
        end
      end
    }
    @missing_episodes[cache_name].merge(missing_eps.reject { |k, _| k.is_a?(Symbol) })
  end
end
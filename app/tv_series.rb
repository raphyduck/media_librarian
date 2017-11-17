class TvSeries
  attr_accessor :id, :tvdb_id, :name, :overview, :seasons, :first_aired, :genres, :network, :rating, :rating_count, :runtime,
                :actors, :banners, :air_time, :imdb_id, :content_rating, :status, :url

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

  def self.identifier(series_name, season, episode, part)
    "tv#{series_name}S#{season.to_i}E#{episode.to_i}P#{part}"
  end

  def self.list_missing_episodes(episodes_in_files, no_prompt = 0, delta = 10, include_specials = 0, missing_eps = {})
    tv_episodes = {}
    return missing_eps if episodes_in_files[:shows].nil?
    episodes_in_files[:shows].each do |series_name, show|
      _, tv_episodes[series_name] = MediaInfo.tv_episodes_search(series_name, no_prompt, show)
      tv_episodes[series_name].each do |ep|
        next unless (ep.air_date.to_s != '' && ep.air_date < Time.now - delta.to_i.days) || MediaInfo.media_exist?(episodes_in_files, identifier(series_name, ep.season_number, ep.number.to_i + 1, nil))
        next if include_specials.to_i == 0 && ep.season_number.to_i == 0
        unless MediaInfo.media_exist?(episodes_in_files, identifier(series_name, ep.season_number, ep.number.to_i, nil))
          full_name = "#{series_name} S#{format('%02d', ep.season_number.to_i)}E#{format('%02d', ep.number.to_i)}"
          $speaker.speak_up("Missing #{full_name} - #{ep.name} (aired on #{ep.air_date}).")
          next if Utils.entry_deja_vu?('download', identifier(series_name, ep.season_number, ep.number, 0))
          attrs = {
              :series_name => series_name,
              :episode_season => ep.season_number.to_i,
              :episode => [ep.number.to_i],
              :part => [0]
          }
          missing_eps = MediaInfo.media_add(series_name,
                                            'shows',
                                            full_name,
                                            identifier(series_name, ep.season_number, ep.number, 0),
                                            attrs,
                                            '',
                                            missing_eps
          )
        end
      end
    end
    missing_eps
  end
end
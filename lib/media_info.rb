class MediaInfo

  @last_tvmaze_req = Time.now - 1.day

  def self.clean_title(title)
    title.gsub(/\(I+\) /,'').gsub(' (Video)','')
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
        Speaker.tell_error(e, "tvmaze::show.lookup")
      end
    end
    res = TVMaze::Show.search(title).first if res.nil?
    @last_tvmaze_req = Time.now
    return res, !res.nil?
  rescue => e
    Speaker.tell_error(e, "MediaInfo.tv_series_search")
    return nil, false
  end

  def self.movie_title_lookup(title)
    movie = moviedb_search(title)
    return clean_title(movie.title), movie.url, true
  rescue => e
    Speaker.tell_error(e, "MediaInfo.movie_title_lookup")
    return title, nil, false
  end

  def self.moviedb_search(title, no_output = false)
    Speaker.speak_up("Starting IMDB lookup for #{title}") unless no_output
    movies = Imdb::Search.new(title).movies
    movie = nil
    movies.each do |m|
      movie = m
      next if m.title.match(/\(TV .+\)/)
      break
    end
    return movie
  rescue => e
    Speaker.tell_error(e, "MediaInfo.moviedb_search")
    return nil
  end
end
class MediaInfo

  @last_tvmaze_req = Time.now - 1.day

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
    return movie.title, true
  rescue => e
    Speaker.tell_error(e, "MediaInfo.movie_title_lookup")
    return title, false
  end

  def self.moviedb_search(title, no_output = false)
    Speaker.speak_up("Starting IMDB lookup for #{title}") unless no_output
    Imdb::Search.new(title).movies.first
  rescue => e
    Speaker.tell_error(e, "MediaInfo.moviedb_search")
    return nil
  end
end
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

  def self.moviedb_search(title)
    Speaker.speak_up("Starting IMDB lookup for #{title}")
    res = Imdb::Search.new(title)
    return res.movies.first.title, true
  rescue => e
    Speaker.tell_error(e, "MediaInfo.moviedb_search")
    return title, false
  end
end
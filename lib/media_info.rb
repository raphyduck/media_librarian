class MediaInfo

  @last_tvmaze_req = Time.now - 1.day

  def self.clean_title(title)
    title.gsub(/\(I+\) /,'').gsub(' (Video)','').gsub(/\(TV .+\)/, '') rescue title
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

  def self.movie_title_lookup(title, first_only = false)
    movies = moviedb_search(title)
    found = false
    if movies.empty?
      results = [[title, '']]
    else
      results =  movies.map { |m| [clean_title(m.title), m.url]}
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
end
class Movie
  SHOW_MAPPING = {id: :id, url: :url, released: :release_date, name: :name, genres: :genres}

  SHOW_MAPPING.values.each do |value|
    attr_accessor value
  end

  def initialize(opts)
    SHOW_MAPPING.each do |source, destination|
      send("#{destination}=", opts[source.to_s] || opts[source.to_sym] || fetch_val(source.to_s, opts))
    end
  end

  def fetch_val(valname, opts)
    v = nil
    case valname
      when 'id'
        v = opts['imdb_id']
        if v.to_s == '' && opts['ids']
          v = opts['ids']['imdb']
          v = opts['ids']['trakt'] if v.to_s == ''
          v = opts['ids']['tmdb'] if v.to_s == ''
          v = opts['ids']['slug'] if v.to_s == ''
        end
      when 'name'
        v = opts['title']
        @year = (opts['year'] || year).to_i
        v << " (#{@year})" if MediaInfo.identify_release_year(v).to_i == 0
      when 'released'
        v = opts['release_date']
      when 'url'
        imdb_id = opts['ids']['imdb'] rescue nil
        v = "https://www.imdb.com/title/#{imdb_id}/" if imdb_id
    end
    v
  end

  def release_date
    if @release_date.to_s.match(/^\d{4}$/)
      Time.new(@release_date) rescue nil
    elsif @release_date
      Time.parse(@release_date) rescue nil
    else
      Time.new(@year.to_i)
    end
  end

  def year
    (@year || release_date || Time.now + 3.years).year.to_i
  end

  def self.identifier(movie_name, year)
    "movie#{movie_name}#{year}"
  end

  def self.identify_split_files(filename)
    filename.to_s.scan(/(^|\/|[\. \(])(cd|disc|part) ?(\d{1,2})[\. \)]/i).map { |a| a[2].to_i if a[2].to_i > 0 }
  end

  def self.movie_get(imdb_id)
    cached = Cache.cache_get('movie_get', imdb_id.to_s)
    return cached if cached
    movie = TraktAgent.movie__summary(imdb_id, "?extended=full") rescue nil
    movie = Movie.new(Cache.object_pack(movie, 1))
    title = movie.name
    Cache.cache_add('movie_get', imdb_id.to_s, [title, movie], movie)
    return title, movie
  rescue => e
    $speaker.tell_error(e, "Movie.movie_get")
    Cache.cache_add('movie_get', imdb_id.to_s, ['', nil], nil)
    return '', nil
  end
end
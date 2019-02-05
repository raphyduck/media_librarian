class Movie
  SHOW_MAPPING = {id: :id, ids: :ids, url: :url, released: :release_date, name: :name, genres: :genres, country: :country,
                  set: :set}

  SHOW_MAPPING.values.each do |value|
    attr_accessor value
  end

  def initialize(opts)
    SHOW_MAPPING.each do |source, destination|
      send("#{destination}=", opts[source.to_s] || opts[source.to_sym] || fetch_val(source.to_s, opts))
    end
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    raise e
  end

  def fetch_val(valname, opts)
    v = nil
    case valname
    when 'country'
      v = opts['production_countries'].first['name'] rescue nil
    when 'genres'
      v = opts['genre']
    when 'id'
      v = opts['imdb_id']
      if v.to_s == '' && opts['ids']
        v = opts['ids']['imdb']
        v = opts['ids']['trakt'] if v.to_s == ''
        v = opts['ids']['tmdb'] if v.to_s == ''
        v = opts['ids']['slug'] if v.to_s == ''
      else
        v = opts['imdbnumber']
      end
    when 'ids'
      v = {'imdb' => (opts['imdb_id'] || opts['imdbnumber'])} if opts['imdb_id'] || opts['imdbnumber']
      v = {'tmdb' => opts['id']} if v.nil? && opts['id']
    when 'name'
      v = opts['original_title'] || opts['title']
      #TODO: Fetch original title from trakt
      v << " (#{year})" if MediaInfo.identify_release_year(v).to_i == 0
    when 'released'
      v = opts['release_date'] || opts['premiered']
    when 'set'
      v = MoviesSet.new(opts['belongs_to_collection']) if opts['belongs_to_collection'].to_s != ''
    when 'url'
      imdb_id = opts['imdb_id'] || opts['ids']['imdb'] rescue nil
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
    return @year if @year
    real_year = TraktAgent.movie__releases(ids['imdb'], '').map {|r| Time.parse(r['release_date']).year}.min rescue nil #We need the year to be the same as IMDB, the authority on movies naming
    title_year = name && MediaInfo.identify_release_year(name) > 0 ? MediaInfo.identify_release_year(name) : nil
    $speaker.speak_up "Unknow year for m='#{Cache.object_pack(self, 1)}'" if (real_year || title_year || release_date).nil? #REMOVEME
    @year ||= (real_year || title_year || (release_date || Time.now + 3.years).year).to_i
  end

  def self.identifier(movie_name, year)
    "movie#{movie_name}#{year}"
  end

  def self.identify_split_files(filename)
    filename.to_s.scan(/(^|\/|[#{SPACE_SUBSTITUTE}\(])((cd|disc)[#{SPACE_SUBSTITUTE}]?(\d{1,2}[#{SPACE_SUBSTITUTE}\)]?)|part[#{SPACE_SUBSTITUTE}]?(\d{1,2})[#{SPACE_SUBSTITUTE}\)]?.{0,2}\.\w{2,4}$)/i).map {|a| (a[4] || a[3]).to_i if (a[4] || a[3]).to_i > 0}
  end

  def self.movie_get(ids, type = 'movie_get', movie = nil)
    $speaker.speak_up(Utils.arguments_dump(binding)) if Env.debug?
    cache_name = ids.map {|k, v| k.to_s + v.to_s if v.to_s != ''}.join
    cached = Cache.cache_get(type, cache_name)
    return cached if cached
    title, full_save = '', movie
    case type
    when 'movie_get'
      if movie.nil? && (ids['trakt'].to_s != '' || ids['imdb'].to_s != '' || ids['slug'].to_s != '')
        movie = TraktAgent.movie__summary((ids['trakt'] || ids['imdb'] || ids['slug']), "?extended=full") rescue nil
      end
      movie = $tmdb.movie(ids['tmdb'] || ids['imdb']) rescue nil if (movie.nil? || movie['error']) && (ids['tmdb'] || ids['imdb']).to_s != ''
      movie = Movie.new(Cache.object_pack(movie, 1)) if movie #&& (movie['title'] || movie['name']).to_s != ''
      full_save = movie
      title = movie.name if movie&.name.to_s != ''
      #TODO: Always use original title
    when 'movie_set_get'
      if ids['tmdb'].to_s == ''
        _, m = movie_get(ids)
        ids = {'tmdb' => m.ids['tmdb']} if m
      end
      _, m = movie_get({'tmdb' => ids['tmdb']})
      movie = $tmdb.collection(m.set.id) if $tmdb && m&.set.to_s != ''
      movie = MoviesSet.new(Cache.object_pack(movie, 1)) if movie.is_a?(Hash)
      title = movie.name if movie&.name.to_s != ''
      full_save = movie || {}
    end
    Cache.cache_add(type, cache_name, [title, movie], full_save)
    return title, movie
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    Cache.cache_add(type, cache_name, ['', nil], nil)
    return '', nil
  end
end
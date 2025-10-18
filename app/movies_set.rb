class MoviesSet
  SHOW_MAPPING = {id: :id, name: :name, movies: :movies}

  SHOW_MAPPING.values.each do |value|
    attr_accessor value
  end

  def initialize(opts)
    SHOW_MAPPING.each do |source, destination|
      send("#{destination}=", opts[source.to_s] || opts[source.to_sym] || fetch_val(source.to_s, opts))
    end
  rescue => e
    MediaLibrarian.app.speaker.tell_error(e, Utils.arguments_dump(binding))
    raise e
  end

  def fetch_val(valname, opts)
    v = nil
    case valname
    when 'movies'
      return v if opts['parts'].nil?
      v = []
      opts['parts'].each do |m|
        _, movie = Movie.movie_get({'tmdb' => m['id']})
        v << movie if movie.name.to_s != ''
      end
    end
    v
  end

  def self.list_missing_movie(movies_files, qualifying_files, no_prompt = 0, delta = 30)
    MediaLibrarian.app.speaker.speak_up Utils.arguments_dump(binding) if Env.debug?
    collections, missing_movies = [], {}
    movies_files.each do |id, movie|
      next if id.is_a?(Symbol)
      collec_title, collection = Movie.movie_get(movie[:movie].ids, 'movie_set_get')
      next if !collection.is_a?(MoviesSet) || collections.include?(collec_title) || !collection.movies.is_a?(Array)
      MediaLibrarian.app.speaker.speak_up("Checking movies set '#{collec_title}' for missing part") if Env.debug?
      collections << collec_title
      collection.movies.each do |m|
        begin ##REMOVEME
          MediaLibrarian.app.speaker.speak_up "Checking movie '#{m.name}', released '#{m.release_date}', in collection" if Env.debug?
          next if (m.release_date.to_s == '' && m.year > Time.now.year.to_i) || m.release_date > Time.now - delta.to_i.days
          next if Metadata.media_exist?(qualifying_files, Movie.identifier(m.name, m.year))
          full_name, identifiers, info = Metadata.parse_media_filename(m.name, 'movies', m, m.name, no_prompt)
          info.merge!({:files => Metadata.media_get(
              movies_files,
              Movie.identifier(full_name, m.year)
          ).map {|_, f| f[:files]}.flatten})
          Metadata.missing_media_add(
              missing_movies,
              'movies',
              full_name,
              m.release_date,
              full_name,
              identifiers,
              info
          )
        rescue => e ##REMOVEME
          MediaLibrarian.app.speaker.tell_error(e, "Block in MovieSet.list_missing_movie() m='#{Cache.object_pack(m,1)}'") ##REMOVEME
        end ##REMOVEME
      end
    end
    missing_movies
  end
end
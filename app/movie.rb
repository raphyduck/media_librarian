require 'timeout'
require 'socket'
class Movie
  include MediaLibrarian::AppContainerSupport

  attr_reader :app

  SHOW_MAPPING = {
    id: :id,
    ids: :ids,
    langsearch: :language,
    url: :url,
    released: :release_date,
    name: :name,
    genres: :genres,
    country: :country,
    rating: :rating,
    set: :set,
    alt_titles: :alt_titles,
    data_source: :data_source
  }.freeze

  SHOW_MAPPING.values.each do |attr|
    attr_accessor attr
  end

  def initialize(opts, app: self.class.app)
    self.class.configure(app: app)
    @app = app
    assign_attributes(opts)
    year
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding))
    raise e
  end

  def assign_attributes(opts)
    SHOW_MAPPING.each do |source, destination|
      value = opts[source.to_s] || opts[source.to_sym] || extract_value(source.to_s, opts)
      send("#{destination}=", value)
    end
  end

  def extract_value(key, opts)
    result = nil
    case key
    when 'alt_titles'
      raw_titles = [opts['original_title'], opts['title']].compact
      result = raw_titles.map do |title|
        release_year = Metadata.identify_release_year(title).to_i
        release_year != year ? "#{title} (#{year})" : title
      end.uniq
    when 'country'
      result = opts['production_countries']&.first&.[]('name')
    when 'genres'
      result = opts['genre']
    when 'id'
      result = opts['imdb_id']
      if result.to_s.empty? && opts['ids']
        result = opts['ids']['imdb']
        result = opts['ids']['trakt'] if result.to_s.empty?
        result = opts['ids']['tmdb'] if result.to_s.empty?
        result = opts['ids']['slug'] if result.to_s.empty?
      else
        result = opts['imdbnumber']
      end
    when 'ids'
      result = { 'imdb' => (opts['imdb_id'] || opts['imdbnumber']) }
      if opts['data_source'].to_s != '' && result[opts['data_source']].to_s.empty?
        result[opts['data_source']] = opts['id']
      end
    when 'langsearch'
      result = Languages.get_code(opts['original_language'] || opts['language'])
    when 'name'
      base_name = opts['original_title'] || opts['title'] || opts['force_title']
      unless base_name
        fallback = opts.dig('ids', 'slug') || opts.dig('ids', 'imdb') || opts.dig('ids', 'trakt') || opts.dig('ids', 'tmdb') ||
                   opts['imdb_id'] || opts['imdbnumber'] || opts['id']
        if fallback
          base_name = fallback.to_s
          app.speaker.speak_up("Movie.extract_value missing title, using fallback: #{base_name}")
        else
          app.speaker.speak_up("Movie.extract_value missing title, no fallback available: #{opts.inspect}")
          return nil
        end
      end
      result = Metadata.identify_release_year(base_name).to_i != year ? "#{base_name} (#{year})" : base_name
    when 'released'
      result = opts['release_date'] || opts['premiered']
    when 'set'
      result = MoviesSet.new(opts['belongs_to_collection'], app: app) if opts['belongs_to_collection'].to_s != ''
    when 'url'
      imdb_id = opts['imdb_id'] || (opts['ids'] && opts['ids']['imdb'])
      result = "https://www.imdb.com/title/#{imdb_id}/" if imdb_id
    end
    result
  end

  def release_date
    if @release_date.to_s =~ /^\d{4}$/
      Time.new(@release_date) rescue nil
    elsif @release_date
      Time.parse(@release_date) rescue nil
    else
      return nil if @year.to_i.zero?

      Time.new(@year.to_i)
    end
  end

  def year
    return @year if @year

    release_time = release_date
    release_year = release_time&.year
    release_year = nil if release_year&.zero?
    extracted_year = nil
    if name
      identified_year = Metadata.identify_release_year(name)
      extracted_year = identified_year if identified_year.to_i.positive?
    end

    real_year = nil
    if release_year.nil? && extracted_year.nil?
      imdb_or_trakt = ids['imdb'] || ids['trakt'] rescue ''
      real_year = if imdb_or_trakt.to_s != ''
                    begin
                      TraktAgent.movie__releases(imdb_or_trakt, '')
                                .filter_map do |release|
                                  date = release['release_date']
                                  next unless date

                                  Time.parse(date).year
                                rescue ArgumentError
                                  nil
                                end
                                .min
                    rescue StandardError
                      nil
                    end
                  end
    end

    if (real_year || extracted_year || release_year).nil?
      app.speaker.speak_up "Unknown year for m='#{Cache.object_pack(self, 1)}'"
    end

    fallback_year = (release_time || Time.now + 3.years).year
    @year ||= (release_year || extracted_year || real_year || fallback_year).to_i
  end

  def self.identifier(movie_name, year)
    "movie#{movie_name}#{year}"
  end

  def self.identify_split_files(filename)
    filename.to_s.scan(/(^|\/|[#{SPACE_SUBSTITUTE}\(])((cd|disc)[#{SPACE_SUBSTITUTE}]?(\d{1,2}[#{SPACE_SUBSTITUTE}\)]?)|part[#{SPACE_SUBSTITUTE}]?(\d{1,2})[#{SPACE_SUBSTITUTE}\)]?.{0,2}[\.\w{2,4}]?$)/i)
            .map { |match| file_part = (match[4] || match[3]).to_i; file_part if file_part > 0 }
            .compact
  end

  NETWORK_TIMEOUT_ERRORS = [Timeout::Error, SocketError].tap do |errors|
    errors << Net::OpenTimeout if defined?(Net::OpenTimeout)
    errors << Net::ReadTimeout if defined?(Net::ReadTimeout)
  end.freeze

  def self.movie_get(ids, type = 'movie_get', movie = nil, app: self.app)
    cache_name = ids.map { |k, v| v.to_s.empty? ? nil : "#{k}#{v}" }.compact.join
    return '', nil if cache_name.empty?

    cached = Cache.cache_get(type, cache_name)
    return cached if cached

    title = ''
    full_save = movie
    case type
    when 'movie_get'
      if movie.nil? && ids['tmdb'].to_s != ''
        tmdb_id = ids['tmdb']
        tmdb_movie = lookup_with_timeout(app, 'tmdb') { Tmdb::Movie.detail(tmdb_id) }
        if tmdb_movie
          movie = Cache.object_pack(tmdb_movie, 1)
          src = 'tmdb'
          imdb_id = tmdb_movie['imdb_id']
          ids['imdb'] = imdb_id if ids['imdb'].to_s == '' && imdb_id.to_s != ''
        elsif Env.debug?
          app.speaker.speak_up("tmdb detail lookup returned nil for id=#{ids['tmdb']}, source=tmdb")
        end
      end
      if (movie.nil? || movie['title'].nil?)
        if ids['imdb'].to_s == '' && ids['tmdb'].to_s != ''
          tmdb_ids = lookup_with_timeout(app, 'tmdb') { Tmdb::Movie.external_ids(ids['tmdb']) }
          imdb_id = tmdb_ids && (tmdb_ids['imdb_id'] || tmdb_ids.dig('external_ids', 'imdb_id'))
          ids['imdb'] = imdb_id if imdb_id.to_s != ''
        end
      end
      if (movie.nil? || movie['title'].nil?) && (ids['trakt'].to_s != '' || ids['imdb'].to_s != '' || ids['slug'].to_s != '')
        trakt_movie = lookup_with_timeout(app, 'trakt') do
          TraktAgent.movie__summary(ids['trakt'] || ids['imdb'] || ids['slug'], "?extended=full")
        end
        if trakt_movie
          movie = Cache.object_pack(trakt_movie, 1)
          src = 'trakt'
        end
      end
      movie = Movie.new(movie.merge('data_source' => src), app: app) if movie
      full_save = movie
      title = movie.name if movie&.name.to_s != ''
    when 'movie_set_get'
      if ids['tmdb'].to_s.empty?
        _, m = movie_get(ids, app: app)
        ids = { 'tmdb' => m.ids['tmdb'] } if m
      end
      _, m = movie_get({ 'tmdb' => ids['tmdb'] }, app: app)
      if m&.set.to_s != ''
        collection_detail = Tmdb::Collection.detail(m.set.id)
        movie = collection_detail.is_a?(Hash) ? MoviesSet.new(Cache.object_pack(collection_detail, 1), app: app) : collection_detail
      end
      title = movie.name if movie&.name.to_s != ''
      full_save = movie || {}
    end
    Cache.cache_add(type, cache_name, [title, movie], full_save)
    app.speaker.speak_up "#{Utils.arguments_dump(binding)}= '', nil" if movie.nil?
    return title, movie
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding))
    Cache.cache_add(type, cache_name, ['', nil], nil)
    return '', nil
  end

  def self.lookup_with_timeout(app, source, &block)
    return unless block

    Timeout.timeout(15) { block.call }
  rescue *NETWORK_TIMEOUT_ERRORS => e
    app.speaker.tell_error(e, "Movie.movie_get #{source} lookup timed out")
    app.speaker.speak_up("Movie.movie_get #{source} lookup #{e.class}: #{e.message}") if Env.debug?
    nil
  rescue StandardError => e
    app.speaker.tell_error(e, "Movie.movie_get #{source} lookup failed")
    app.speaker.speak_up("Movie.movie_get #{source} lookup #{e.class}: #{e.message}") if Env.debug?
    nil
  end

  def self.movie_search(title, no_prompt = 0, original_filename = '', ids = {}, app: self.app, force_refresh: 0)
    Metadata.media_lookup(
      'movies',
      title,
      'movie_lookup',
      { 'name' => 'name', 'titles' => 'alt_titles', 'url' => 'url', 'year' => 'year' },
      ->(search_ids) { movie_get(search_ids, app: app) },
      [[self, :tmdb_search], [TraktAgent, :search__movies]],
      no_prompt,
      original_filename,
      ids,
      force_refresh: force_refresh
    )
  end

  def self.tmdb_search(title)
    Tmdb::Movie.find(title)
  end
end

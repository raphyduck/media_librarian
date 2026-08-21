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
    opts = normalize_opts(opts)
    SHOW_MAPPING.each do |source, destination|
      value = opts[source.to_s] || extract_value(source.to_s, opts)
      value = self.class.drop_blank_ids(value) if destination == :ids
      send("#{destination}=", value)
    end
  end

  # TMDB answers with an empty imdb_id far more often than a null one, and a
  # blank string is truthy in Ruby: kept verbatim it satisfies every
  # `ids['imdb'] || fallback` chain downstream, so the title travels as if it
  # had an IMDb id and lands in the library unmatched. Blank means absent.
  def self.drop_blank_ids(ids)
    return ids unless ids.is_a?(Hash)

    ids.each_with_object({}) do |(key, value), memo|
      memo[key] = value.to_s.strip.empty? ? nil : value
    end
  end
  def normalize_opts(opts)
    return {} unless opts
    return opts unless opts.is_a?(Hash)

    opts.each_with_object({}) do |(key, value), result|
      result[key.to_s] = value.is_a?(Hash) ? normalize_opts(value) : value
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
      if result.to_s.empty?
        if opts['ids']
          result = opts['ids']['imdb']
          result = opts['ids']['trakt'] if result.to_s.empty?
          result = opts['ids']['tmdb'] if result.to_s.empty?
          result = opts['ids']['slug'] if result.to_s.empty?
        else
          # Kodi payloads carry imdbnumber instead of imdb_id/ids.
          result = opts['imdbnumber']
        end
      end
    when 'ids'
      imdb_id = [opts['imdb_id'], opts['imdbnumber']].map { |value| value.to_s.strip }.find { |value| !value.empty? }
      result = { 'imdb' => imdb_id }
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

  def inspect
    "#<Movie name=#{@name.inspect} year=#{@year} ids=#{@ids.inspect}>"
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
    ids = ids.transform_keys(&:to_s)
    cache_name = ids.map { |k, v| v.to_s.empty? ? nil : "#{k}#{v}" }.compact.join
    return '', nil if cache_name.empty?

    cached = Cache.cache_get(type, cache_name)
    return cached if cached

    title = ''
    full_save = movie
    case type
    when 'movie_get'
      if movie.nil? && (ids['tmdb'].to_s != '' || ids['imdb'].to_s != '')
        # TMDB movie endpoints accept IMDb ids in place of TMDB ids; querying
        # TMDB first keeps the original title (Trakt only carries the English
        # one), which torrent searches rely on.
        tmdb_id = ids['tmdb'].to_s != '' ? ids['tmdb'] : ids['imdb']
        tmdb_movie = lookup_with_timeout(app, 'tmdb') { Tmdb::Movie.detail(tmdb_id) }
        tmdb_movie = tmdb_movie && Cache.object_pack(tmdb_movie, 1)
        if tmdb_movie && tmdb_movie['title'].to_s != ''
          movie = tmdb_movie
          src = 'tmdb'
          imdb_id = movie['imdb_id']
          ids['imdb'] = imdb_id if ids['imdb'].to_s == '' && imdb_id.to_s != ''
          ids['tmdb'] = movie['id'] if ids['tmdb'].to_s == '' && movie['id'].to_s != ''
        elsif Env.debug?
          app.speaker.speak_up("tmdb detail lookup returned nil for id=#{tmdb_id}, source=tmdb")
        end
      end
      # This backfill used to be gated on the movie having failed to resolve,
      # so it never ran for the case that actually loses the id: TMDB answering
      # with a perfectly good movie whose imdb_id is blank. The tmdb id is
      # authoritative for the record already chosen, so asking TMDB for its
      # external_ids adds the missing id without changing which film was
      # picked — and leaves the id absent when TMDB genuinely knows of none.
      if ids['imdb'].to_s.strip.empty? && ids['tmdb'].to_s != ''
        tmdb_ids = lookup_with_timeout(app, 'tmdb') { Tmdb::Movie.detail(ids['tmdb'], append_to_response: 'external_ids') }
        # The top-level imdb_id is the blank that sent us here, so it must not
        # shadow the external_ids block that actually carries the answer.
        imdb_id = tmdb_ids && [tmdb_ids['imdb_id'], tmdb_ids.dig('external_ids', 'imdb_id')]
                              .map { |value| value.to_s.strip }.find { |value| !value.empty? }
        ids['imdb'] = imdb_id if imdb_id.to_s.strip != ''
      end

      # Movie.new rebuilds its ids from the payload, so a backfilled id has to
      # be written back onto it or the object comes out blank all the same.
      if movie.is_a?(Hash) && movie['imdb_id'].to_s.strip.empty? && ids['imdb'].to_s.strip != ''
        movie = movie.merge('imdb_id' => ids['imdb'])
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
      if movie && movie.name.to_s.strip == ''
        app.speaker.speak_up("movie_get: discarding empty movie from #{src} for ids=#{ids.inspect}") if Env.debug?
        movie = nil
      end
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

  # Searching without a year forced media_chose to referee every homonym after
  # the fact. TMDB's `year` filter matches any release date — festival
  # premieres included — and ranks what is left by popularity, the same query
  # media-center scanners rely on, so when the folder names a year the
  # shortlist arrives pre-disambiguated. primary_release_year would be wrong
  # here: folders carry the IMDb premiere year while TMDB's primary release
  # is often the year after (Influencer: 2022 premiere, 2023 release), and
  # that filter would exclude the very film being looked for. A miss (a bogus
  # year in the folder name) falls back to the plain search rather than
  # returning nothing.
  def self.tmdb_search(title, year = nil)
    if year.to_i > 0
      search = Tmdb::Search.new('/search/movie')
      search.query(title)
      search.year(year.to_i)
      results = Array(search.fetch).map { |result| Tmdb::Movie.new(result) }
      return results unless results.empty?
    end
    Tmdb::Movie.find(title)
  end
end

class BookSeries
  include MediaLibrarian::AppContainerSupport

  attr_reader :app
  attr_accessor :name, :goodread_id, :description

  @book_series = {}

  def initialize(opts, app: self.class.app)
    self.class.configure(app: app)
    @app = app
    @name = (opts['name'] || opts['title'] || opts[:name] || opts[:title]).to_s.strip
    @goodread_id = opts['goodread_id'] || opts['id']
    @description = opts['description'].to_s.strip
  end

  def identifier
    "book#{name}#{goodread_id}"
  end

  def self.book_series_search(title, ids = {}, goodread_id = '', app: self.app)
    cache_name = title.to_s + ids['isbn'].to_s + goodread_id.to_s
    cached = Cache.cache_get('book_series_search', cache_name)
    return cached if cached
    exact_title, series = '', nil
    if goodread_id.to_s != ''
      exact_title, series = get_series(goodread_id)
    end
    if series.nil? && ids && ids['goodreads'].to_s != ''
      book = app.goodreads.book(ids['goodreads'])
      series_id = if book['series_works']['series_work'].is_a?(Array)
                    book['series_works']['series_work'][0]
                  else
                    book['series_works']['series_work']
                  end['series']['id'] rescue nil
      exact_title, series = get_series(series_id, app: app) if series_id
      series = {} if series.nil?
    end
    Cache.cache_add('book_series_search', cache_name, [exact_title, series], series)
    return exact_title, series
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding))
    Cache.cache_add('book_series_search', cache_name, ['', nil], nil)
    return '', nil
  end

  def self.existing_series(app: self.app)
    return @book_series if app.calibre.nil?
    @book_series = app.calibre.get_rows('series').map { |s| s[:name] }
    @book_series
  end

  def self.get_series(goodread_series_id, app: self.app)
    cached = Cache.cache_get('books_series_get', goodread_series_id.to_s)
    return cached if cached
    series = app.goodreads.series(goodread_series_id)
    return '', nil if series.nil?
    series = BookSeries.new(series, app: app)
    title = series.name
    Cache.cache_add('books_series_get', goodread_series_id.to_s, [title, series], series)
    return title, series
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding))
    Cache.cache_add('books_series_get', goodread_series_id.to_s, ['', nil], nil)
    return '', nil
  end

  def self.subscribe_series(no_prompt = 1, app: self.app)
    cache_name = 'subscribe_series'
    book_series = BusVariable.new('book_series', Vash)
    return book_series[cache_name] if book_series[cache_name] && !book_series[cache_name].empty?
    book_series[cache_name, CACHING_TTL] = {}
    Utils.lock_block("#{__method__}_#{cache_name}") {
      existing_series(app: app).each do |series_name|
        series_name = series_name.dup
        full_name, identifiers, info = Metadata.parse_media_filename(series_name, 'books', new({'name' => series_name}, app: app), series_name.dup, no_prompt)
        book_series[cache_name, CACHING_TTL] = Metadata.media_add(series_name,
                                                                  'books',
                                                                  full_name,
                                                                  identifiers,
                                                                  info,
                                                                  {},
                                                                  {},
                                                                  book_series[cache_name]
        )
      end
    }
    book_series[cache_name]
  end
end
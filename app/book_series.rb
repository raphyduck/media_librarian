class BookSeries
  attr_accessor :name, :goodread_id, :description

  def initialize(opts)
    @name = (opts['name'] || opts['title'] || opts[:name] || opts[:title]).to_s.strip
    @goodread_id = opts['goodread_id'] || opts['id']
    @description = opts['description'].to_s.strip
  end

  def identifier
    "book#{name}#{goodread_id}"
  end

  def self.book_series_search(title, no_prompt, ids = {}, goodread_id = '')
    cache_name = title.to_s + ids['isbn'].to_s + goodread_id.to_s
    cached = Cache.cache_get('book_series_search', cache_name)
    return cached if cached
    exact_title, series = '', nil
    if goodread_id.to_s != ''
      exact_title, series = get_series(goodread_id)
    end
    if series.nil?
      _, book = Book.book_search(title, no_prompt, ids, 1)
      if book
        bid = book.is_a?(Book) ? book.ids['goodreads'] : book[:id]
        book = bid.nil? ? {} : $goodreads.book(bid)
        series_id = if book['series_works']['series_work'].is_a?(Array)
                      book['series_works']['series_work'][0]
                    else
                      book['series_works']['series_work']
                    end['series']['id'] rescue nil
        exact_title, series = get_series(series_id) if series_id
        series = {} if series.nil?
      end
    end
    Cache.cache_add('book_series_search', cache_name, [exact_title, series], series)
    return exact_title, series
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    Cache.cache_add('book_search', cache_name, ['', nil], nil)
    return '', nil
  end

  def self.get_series(goodread_series_id)
    cached = Cache.cache_get('books_series_get', goodread_series_id.to_s)
    return cached if cached
    series = $goodreads.series(goodread_series_id)
    return '', nil if series.nil?
    series = BookSeries.new(series)
    title = series.name
    Cache.cache_add('books_series_get', goodread_series_id.to_s, [title, series], series)
    return title, series
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    Cache.cache_add('books_series_get', goodread_series_id.to_s, ['', nil], nil)
    return '', nil
  end

  def self.subscribe_series(no_prompt = 1)
    cache_name = 'subscribe_series'
    book_series = BusVariable.new('book_series', Vash)
    return book_series[cache_name] if book_series[cache_name] && !book_series[cache_name].empty?
    book_series[cache_name, CACHING_TTL] = {}
    Utils.lock_block("#{__method__}_#{cache_name}") {
      series = Book.existing_books(no_prompt)
      (series[:book_series] || {}).each do |series_name, s|
        series_name = series_name.dup
        full_name, identifiers, info = MediaInfo.parse_media_filename(series_name, 'books', s, series_name.dup, no_prompt)
        book_series[cache_name, CACHING_TTL] = MediaInfo.media_add(series_name,
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
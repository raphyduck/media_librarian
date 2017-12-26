class BookSeries
  attr_accessor :name, :goodread_id, :description

  def initialize(opts)
    @name = (opts['name'] || opts['title']).to_s.strip
    @goodread_id = opts['goodread_id'] || opts['id']
    @description = opts['description'].to_s.strip
  end

  def self.book_series_search(title, no_prompt, isbn = '', goodread_id = '')
    #TODO: Complete this function
    cache_name = title.to_s + isbn.to_s + goodread_id.to_s
    cached = Cache.cache_get('book_series_search', cache_name)
    return cached if cached
    exact_title, series = '', nil
    if goodread_id.to_s != ''
      exact_title, series = get_series(goodread_id)
    end
    if series.nil?
      _, book = Book.book_search(title, no_prompt, isbn)
      if book
        bid = book.is_a?(Book) ? book.ids['goodreads'] : book[:id]
        book = $goodreads.book(bid)
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
    $speaker.tell_error(e, "BookSeries.book_series_search")
    Cache.cache_add('book_search', cache_name, ['', nil], nil)
    return '', nil
  end

  def self.identifier(name, goodread_id, nb)
    "bookseries#{name}#{goodread_id}#{nb}"
  end

  def self.get_series(goodread_series_id)
    cached = Cache.cache_get('books_series_get', goodread_series_id.to_s)
    return cached if cached
    series = $goodreads.series(goodread_series_id)
    series = BookSeries.new(series)
    title = series.name
    Cache.cache_add('books_series_get', goodread_series_id.to_s, [title, series], series)
    return title, series
  rescue => e
    $speaker.tell_error(e, "BookSeries.get_series")
    Cache.cache_add('books_series_get', goodread_series_id.to_s, ['', nil], nil)
    return '', nil
  end

  def self.subscribe_series
    series = {}
    return series if $calibre.nil?
    $calibre.get_rows('series').each do |s|
      full_name, identifiers, info = MediaInfo.parse_media_filename(s[:name], 'book_series')
      series = MediaInfo.media_add(s[:name],
                                   'book_series',
                                   full_name,
                                   identifiers,
                                   info,
                                   {},
                                   {},
                                   series
      ) if full_name != '' && !identifiers.empty?
    end
    series
  end
end
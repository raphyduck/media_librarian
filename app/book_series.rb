class BookSeries
  attr_accessor :name, :goodread_id, :description, :identifier

  def initialize(opts)
    @name = opts['title'].strip
    @goodread_id = opts['id']
    @description = opts['description'].strip
    @identifier = "bookseries#{@name}#{@goodread_id}"
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
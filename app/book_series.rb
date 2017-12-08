class BookSeries
  attr_accessor :name

  def initialize(name)
    @name = name
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
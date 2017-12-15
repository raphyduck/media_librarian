class Movie
  SHOW_MAPPING = {id: :id, url: :url, release_date: :release_date, name: :name, genres: :genres}

  SHOW_MAPPING.values.each do |value|
    attr_accessor value
  end

  def initialize(opts)
    SHOW_MAPPING.each do |source, destination|
      send("#{destination}=", opts[source.to_s] || opts[source.to_sym] || fetch_val(source.to_s, opts))
    end
  end

  def fetch_val(valname, opts)
    case valname
      when 'id'
        v = opts['imdb_id']
    when 'name'
      v = opts['title']
      v << " (#{year})" if MediaInfo.identify_release_year(v).to_i == 0
    end
    v
  end

  def release_date
    if @release_date.to_s.match(/^\d{4}$/)
      Time.new(@release_date) rescue nil
    else
      Time.parse(@release_date) rescue nil
    end
  end

  def year
    (release_date || Time.now + 3.years).year.to_i
  end

  def self.identifier(movie_name, year)
    "movie#{movie_name}#{year}"
  end

  def self.identify_split_files(filename)
    filename.to_s.scan(/(^|\/|[\. \(])(cd|disc|part) ?(\d{1,2})[\. \)]/i).map{|a| a[2].to_i if a[2].to_i > 0}
  end
end
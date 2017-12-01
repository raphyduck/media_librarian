class Movie
  attr_accessor :id, :url, :title, :genres, :release_date

  def initialize(options = {})
    @id = options['imdb_id']
    @url = options['url']
    @title = options['title']
    @release_date = options['release_date']
    @genres = options['genres']
    year = DateTime.parse(@release_date).year.to_i rescue (Time.now + 3.years).year.to_i
    @title += " (#{year})" if MediaInfo.identify_release_year(@title).to_i == 0
  end

  def self.identifier(movie_name, year)
    "movie#{movie_name}#{year}"
  end

  def self.identify_split_files(filename)
    filename.to_s.scan(/(^|\/|[\. \(])(cd|disc|part) ?(\d{1,2})[\. \)]/i).map{|a| a[2].to_i if a[2].to_i > 0}
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
end
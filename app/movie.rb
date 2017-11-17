class Movie
  attr_accessor :id, :url, :title, :genres, :release_date

  def initialize(options = {})
    @id = options['imdb_id']
    @url = options['url']
    @title = options['title']
    @release_date = options['release_date']
    @genres = options['genres']
    year = DateTime.parse(@release_date).year.to_i rescue (Date.today + 3.years).year.to_i
    @title += " (#{year})" if MediaInfo.identify_release_year(@title).to_i == 0
  end

  def self.identifier(movie_name, year)
    "movie#{movie_name}#{year}"
  end

  def release_date
    DateTime.parse(@release_date) rescue nil
  end

  def year
    (release_date || Date.today + 3.years).year.to_i
  end
end
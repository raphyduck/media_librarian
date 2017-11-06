class Movie
  attr_accessor :id, :url, :title, :genres, :release_date

  def initialize(options = {})
    @id = options['imdb_id']
    @url = options['url']
    @title = options['title']
    @release_date = options['release_date']
    @genres = options['genres']
  end

  def self.identifier(movie_name, year)
    "#{movie_name}#{year}"
  end

  def release_date
    DateTime.parse(@release_date) rescue nil
  end

  def title
    t = @title
    t += " (#{year})" if MediaInfo.identify_release_year(@title).to_i == 0
    t
  end

  def year
    (release_date || Date.today + 3.years).year.to_i
  end
end
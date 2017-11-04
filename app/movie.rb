class Movie
  attr_accessor :id, :url, :title, :genres, :release_date

  def initialize(options = {})
    @id = options['imdb_id']
    @url = options['url']
    @title = options['title']
    @release_date = options['release_date']
    @genres = options['genres']
  end

  def self.identifier(movie_name)
    "#{movie_name}"
  end

  def release_date
    DateTime.parse(@release_date) rescue nil
  end
end
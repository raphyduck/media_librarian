class Episode
  attr_accessor :id, :series_id, :season_number, :number, :name, :overview, :air_date, :guest_stars, :director, :writer, :rating, :rating_count

  def initialize(options)
    @id = options["id"]
    @season_number = options["season_number"]
    @number = options["number"]
    @name = options["name"]
    @overview = options["overview"]
    @director = options["director"]
    @writer = options["writer"]
    @series_id = options["series_id"]
    @rating_count = options["rating_count"]
    @guest_stars = options["guest_stars"]
    @rating = options["rating"]
    @rating_count = options["rating_count"]
    @air_date = options["air_date"]
  end
end
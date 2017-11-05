class Episode
  MAPPING = { id: :id, series_id: :series_id, season_number: :season_number,
              number: :number, name: :name, overview: :overview,
              air_date: :air_date, guest_stars: :guest_stars,
              director: :director, writer: :writer, rating: :rating,
              rating_count: :rating_count }
  MAPPING.values.each do |value|
    attr_accessor value
  end

  def initialize(options)
    MAPPING.each do |source, destination|
      send("#{destination}=", options[source.to_s] || options[source.to_sym])
    end
  end

  def air_date
    DateTime.parse(@air_date) rescue nil
  end
end
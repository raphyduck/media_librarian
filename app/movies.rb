class Movies

  def self.identifier(movie_name)
    "#{movie_name}"
  end

  def self.rename_movies_file(original, movies_name, destination, quality = nil, hard_link = 0, replaced_outdated = 0)
    title, _ = MediaInfo.movie_title_lookup(movies_name, true)
    movies_name = title[0]
    quality = quality || File.basename(original).downcase.gsub('-', '').scan(REGEX_QUALITIES).join('.').gsub('-', '')
    extension = original.gsub(/.*\.(\w{2,4}$)/, '\1')
    FILENAME_NAMING_TEMPLATE.each do |k|
      destination = destination.gsub(Regexp.new('\{\{ ' + k + '((\|[a-z]*)+)? \}\}')) { Utils.regularise_media_filename(eval(k), $1) } rescue nil
    end
    destination += ".#{extension.downcase}"
    Utils.move_file(original, destination, hard_link, replaced_outdated)
  end
end
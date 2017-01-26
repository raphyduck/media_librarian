class Library

  def self.moviedb_search(title)
    Speaker.speak_up("Starting IMDB lookup for #{title}")
    res = Imdb::Search.new(title)
    return res.movies.first.title, true
  rescue => e
    Speaker.tell_error(e, "Library.moviedb_search")
    return title, false
  end

  def self.replace_movies(folder, imdb_name_check = 1, filter_criteria = {}, quality_keyword = '', interactive = 1)
    $move_completed_torrent = folder
    self.search_folder(folder, filter_criteria).each do |film|
      next if File.basename(folder) == film[1]
      title = film[1]
      path = film[0]
      next if Speaker.ask_if_needed("Replace #{title} (file is #{File.basename(path)}? (y/n)", interactive) != 'y'
      if imdb_name_check.to_i > 0
        title, found = self.moviedb_search(title)
        #Look for duplicate
        dups = self.search_folder(folder, {'regex' => '.*' + title.gsub(/(\w*)\(\d+\)/,'\1').strip.gsub(/ /,'.') + '.*', 'exclude_strict' => film[1]})
        if dups.count > 0
          if Speaker.ask_if_needed("Duplicate(s) found for film #{title}. Duplicates are:#{NEW_LINE}" + dups.map{|d| "#{d[0]}#{NEW_LINE}"}.to_s + ' Do you want to remove them? (y/n)', interactive) == 'y'
            dups.each do |d|
              FileUtils.rm_r(d[0])
            end
          end
        end
      end
      Speaker.speak_up("Looking for torrent of film #{title}") unless interactive == 0 && !found
      replaced = interactive == 0 && !found ? false : T411Search.search(title + ' ' + quality_keyword, 10, 210, interactive)
      FileUtils.rm_r(File.dirname(path)) if replaced
    end
  rescue => e
    Speaker.tell_error(e, "Library.replace_movies")
  end

  def self.search_folder(folder, filter_criteria = {})
    filter_criteria = eval(filter_criteria) if filter_criteria.is_a?(String)
    search_folder = []
    Find.find(folder).each do |path|
      next if path == folder
      next if FileTest.directory?(path)
      parent = File.basename(File.dirname(path))
      next if File.basename(path).start_with?('.')
      next if parent.start_with?('.')
      next if filter_criteria['name'] && !File.basename(path).include?(filter_criteria['name'])
      next if filter_criteria['regex'] && !File.basename(path).match(filter_criteria['regex'])
      next if filter_criteria['exclude'] && File.basename(path).include?(filter_criteria['exclude'])
      next if filter_criteria['exclude_strict'] && File.basename(path) == filter_criteria['exclude_strict']
      next if filter_criteria['exclude_strict'] && parent == filter_criteria['exclude_strict']
      next if filter_criteria['days_older'] && File.mtime(path) > Time.now - filter_criteria['days_older'].to_i.days
      next if filter_criteria['days_newer'] && File.mtime(path) < Time.now - filter_criteria['days_newer'].to_i.days
      search_folder << [path, parent]
    end
    search_folder
  rescue => e
    Speaker.tell_error(e, "Library.search_folder")
    []
  end

end
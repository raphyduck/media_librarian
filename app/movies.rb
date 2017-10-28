class Movies

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

  def self.replace_movies(folder:, imdb_name_check: 1, filter_criteria: {}, extra_keywords: '', no_prompt: 0, move_to: nil, qualities: {})
    $move_completed_torrent = folder
    Utils.search_folder(folder, filter_criteria).each do |film|
      next if Library.already_processed?(film[1])
      next if File.basename(folder) == film[1]
      break if Library.break_processing(no_prompt)
      path = film[0]
      titles = [[film[1], '']]
      next if Library.skip_loop_item("Replace #{film[1]} (file is #{File.basename(path)})? (y/n)", no_prompt) > 0
      found, replaced, cpt = true, false, 0
      if imdb_name_check.to_i > 0
        titles, found = MediaInfo.movie_title_lookup(titles[0][0])
      end
      titles += [['Edit title manually', '']]
      loop do
        choice = cpt
        break if cpt >= titles.count
        if cpt > 0 && $speaker.ask_if_needed("Look for alternative titles for this file? (y/n)'", no_prompt, 'n') == 'y'
          $speaker.speak_up("Alternatives titles found:")
          idxs = 1
          titles.each do |m|
            $speaker.speak_up("#{idxs}: #{m[0]}#{' (info IMDB: ' + URI.escape(m[1]) + ')' if m[1].to_s != ''}")
            idxs += 1
          end
          choice = $speaker.ask_if_needed("Enter the number of the chosen title: ", no_prompt, 1).to_i - 1
          break if choice < 0 || choice > titles.count
        elsif cpt > 0
          break
        end
        t = titles[choice]
        if t[0] == 'Edit title manually'
          $speaker.speak_up('Enter the title to look for:')
          t[0] = STDIN.gets.strip
        end
        #Look for duplicate
        replaced = Library.duplicate_search(folder, t[0], film, no_prompt, 'movies') if found
        break if replaced
        $speaker.speak_up("Looking for torrent of film #{t[0]}#{' (info IMDB: ' + URI.escape(t[1]) + ')' if t[1].to_s != ''}") unless no_prompt > 0 && !found
        replaced = no_prompt > 0 && !found ? nil : TorrentSearch.search(keywords: t[0] + ' ' + extra_keywords,
                                                                        limit: 10,
                                                                        category: 'movies',
                                                                        no_prompt: no_prompt,
                                                                        filter_dead: 1,
                                                                        move_completed: move_to || folder,
                                                                        rename_main: t[0],
                                                                        main_only: 1,
                                                                        qualities: qualities)
        break if replaced
        cpt += 1
      end
      $dir_to_delete << {:id => found, :d => File.dirname(path).gsub(folder, '')} if replaced.to_i > 0
    end
  rescue => e
    $speaker.tell_error(e, "Library.replace_movies")
  end
end
class Library

  @refusal = 0

  def self.break_processing(no_prompt = 0, threshold = 3)
    if @refusal > threshold
      @refusal = 0
      return Speaker.ask_if_needed("Do you want to stop processing the list now? (y/n)", no_prompt, 'n') == 'y'
    end
    false
  end

  def self.compare_remote_files(path:, remote_server:, remote_user:, filter_criteria: {}, ssh_opts: {}, no_prompt: 0)
    ssh_opts = Utils.recursive_symbolize_keys(eval(ssh_opts)) if ssh_opts.is_a?(String)
    ssh_opts = {} if ssh_opts.nil?
    list = FileTest.directory?(path) ? Utils.search_folder(path, filter_criteria) : [[path, '']]
    list.each do |f|
      f_path = f[0]
      Speaker.speak_up("Comparing #{f_path} on local and remote #{remote_server}")
      local_md5sum = Utils.md5sum(f_path)
      remote_md5sum = ''
      Net::SSH.start(remote_server, remote_user, ssh_opts) do |ssh|
        remote_md5sum = []
        ssh.exec!("md5sum \"#{f_path}\"") do |_, stream, data|
          remote_md5sum << data if stream == :stdout
        end
        remote_md5sum = remote_md5sum.first
        remote_md5sum = remote_md5sum ? remote_md5sum.gsub(/(\w*)( .*\n)/, '\1') : ''
      end
      Speaker.speak_up("Local md5sum is #{local_md5sum}")
      Speaker.speak_up("Remote md5sum is #{remote_md5sum}")
      if local_md5sum != remote_md5sum || local_md5sum == '' || remote_md5sum == ''
        Speaker.speak_up("Mismatch between the 2 files, the remote file might not exist or the local file is incorrectly downloaded")
        if local_md5sum != '' && remote_md5sum != '' && Speaker.ask_if_needed("Delete the local file? (y/n)", no_prompt, 'n') == 'y'
          FileUtils.rm_r(f_path)
        end
      else
        Speaker.speak_up("The 2 files are identical!")
        if Speaker.ask_if_needed("Delete the remote file? (y/n)", no_prompt, 'y') == 'y'
          Net::SSH.start(remote_server, remote_user, ssh_opts) do |ssh|
            ssh.exec!("rm \"#{f_path}\"")
          end
        end
      end
    end
  rescue => e
    Speaker.tell_error(e, "Library.compare_remote_files")
  end

  def self.copy_media_from_list(source_list:, dest_folder:, source_folders: {})
    source_folders = Utils.recursive_symbolize_keys(eval(source_folders)) if source_folders.is_a?(String)
    source_folders = {} if source_folders.nil?
    return Speaker.speak_up("Invalid destination folder") if dest_folder.nil? || dest_folder == '' || !File.exist?(dest_folder)
    list = TraktList.list(source_list, '')
    return Speaker.speak_up("Empty list #{source_list}") if list.empty?
    list = TraktList.parse_custom_list(list)
    list.each do |type, items|
      source_folder = source_folders[type] || Speaker.ask_if_needed("What is the source folder for #{type} media?")
      list_size, paths = get_media_list_size(items, source_folder)
      free_space = Utils.get_free_space(dest_folder)
      while free_space <= list_size
        break if Speaker.ask_if_needed("There is not enough space available on #{File.basename(dest_folder)}. You need an additional #{(list_size-free_space)/1024/1024/1024} GB to copy the list. Do you want to edit the list now?") != 'y'
        create_custom_list(source_list, '')
        list_size, paths = get_media_list_size(items, source_folder)
      end
      folder_names = paths.map { |p| File.basename(p) }
      Utils.search_folder(dest_folder, {'maxdepth' => 1}).each do |p|
        puts "FileUtils.rm_r(#{p})" unless folder_names.include?(File.basename(p))
      end
      paths.each do |p|
        Rsync.run("#{p}/", "#{dest_folder}/#{File.basename(p)}", ['--update', '--times', '--delete', '--recursive']) do |result|
          if result.success?
            result.changes.each do |change|
              puts "#{change.filename} (#{change.summary})"
            end
          else
            puts result.error
          end
        end
      end
    end
  end

  def self.create_custom_list(name:, description:, origin: 'collection', criteria: {})
    Speaker.speak_up("Fetching items from #{origin}...")
    criteria = eval(criteria) if criteria.is_a?(String)
    new_list = {
        'movies' => TraktList.list(origin, 'movies'),
        'shows' => TraktList.list(origin, 'shows')
    }
    existing_lists = TraktList.list('lists')
    dest_list = existing_lists.select { |l| l['name'] == name }.first
    if dest_list
      Speaker.speak_up("List #{name} exists, deleting any items in it...")
      existing = TraktList.list(name)
      to_delete = TraktList.parse_custom_list(existing)
      TraktList.remove_from_list(to_delete, name, '') unless to_delete.nil? || to_delete.empty?
    else
      Speaker.speak_up("List #{name} doesn't exist, creating it...")
      TraktList.create_list(name, description)
    end
    Speaker.speak_up("Ok, we have added #{(new_list['movies'].length + new_list['shows'].length)} items from #{origin}, let's chose what to include in the new list #{name}.")
    ['movies', 'shows'].each do |type|
      t_criteria = criteria[type] || {}
      if t_criteria['noadd'] || Speaker.ask_if_needed("Do you want to add #{type} items? (y/n)", t_criteria.empty? ? 0 : 1, 'y') != 'y'
        new_list.delete(type)
        next
      end
      puts "list count #{new_list[type].length}"
      folder = Speaker.ask_if_needed("What is the path of your folder where #{type} are stored? (in full)", t_criteria['folder'].nil? ? 0 : 1, t_criteria['folder'])
      (type == 'shows' ? ['entirely watched', 'partially watched', 'ended', 'not ended'] : ['watched']).each do |cr|
        if (t_criteria[cr] && t_criteria[cr].to_i == 0) || Speaker.ask_if_needed("Do you want to add #{type} #{cr}? (y/n)", t_criteria[cr].nil? ? 0 : 1, 'y') != 'y'
          new_list[type] = TraktList.filter_trakt_list(new_list[type], type, cr, t_criteria['include'])
          puts "list count #{new_list[type].length}"
        end
      end
      if (t_criteria['no_review'] && t_criteria['no_review'].to_i > 0) || Speaker.ask_if_needed("Do you want to review #{type} individually? (y/n)") == 'y'
        new_list[type].reverse_each do |item|
          title = item[type[0...-1]]['title']
          folders = Utils.search_folder(folder, {'regex' => '.*' + Utils.regexify(title.gsub(/(\w*)\(\d+\)/, '\1')).gsub(/^[Tt]he /, '') + '.*',
                                                 'maxdepth' => 1, 'includedir' => 1, 'return_first' => 1})
          file = folders.first
          if file
            size = Utils.get_disk_size(file[0])
            if Speaker.ask_if_needed("Do you want to add #{type} '#{title}' (disk size #{size/1024/1024/1024} GB) to the list (y/n)") != 'y'
              new_list[type].delete(item)
            elsif type == 'shows' && Speaker.ask_if_needed("Do you want to keep all seasons of #{title}? (y/n)") != 'y'
              choice = Speaker.ask_if_needed("Which seasons do you want to keep? (spearated by comma, like this: '1,2,3'").split(',')
              choice.each do |c|
                item['seasons'].select! { |s| s['number'] != c.to_i }
              end
            end
          elsif Speaker.ask_if_needed("No folder found for #{title}, do you want to delete the item from the list? (y/n)") == 'y'
            Speaker.speak_up("No folder found for #{title}, deleting...")
            new_list[type].delete(item)
          end
        end
      end
      new_list[type].map! do |i|
        i[type[0...-1]]['seasons'] = i['seasons'].map { |s| s.select { |k, _| k != 'episodes' } } if i['seasons']
        i[type[0...-1]]
      end
      TraktList.add_to_list(new_list[type], 'custom', name, type)
    end
    Speaker.speak_up("List #{name} is up to date!")
  rescue => e
    Speaker.tell_error(e, "Library.create_custom_list")
  end

  def self.duplicate_search(folder, title, original, no_prompt = 0, type = 'movies')
    Speaker.speak_up("Looking for duplicates of #{title}...")
    dups = Utils.search_folder(folder, {'regex' => '.*' + title.gsub(/(\w*)\(\d+\)/, '\1').strip.gsub(/ /, '.') + '.*', 'exclude_strict' => original})
    if dups.count > 0
      corrected_dups = []
      dups.each do |d|
        case type
          when 'movies'
            d_title, _ = MediaInfo.moviedb_search(File.basename(File.dirname(d)))
          else
            next
        end
        corrected_dups << d if d_title == title
      end
      if corrected_dups.length > 0 && Speaker.ask_if_needed("Duplicate(s) found for film #{title}. Original is #{original}. Duplicates are:#{NEW_LINE}" + corrected_dups.map { |d| "#{d[0]}#{NEW_LINE}" }.to_s + ' Do you want to remove them? (y/n)', no_prompt) == 'y'
        corrected_dups.each do |d|
          FileUtils.rm_r(d[0])
        end
      end
    end
  end

  def self.get_media_list_size(list, folder)
    list_size = 0
    list_paths = []
    list.each do |item|
      type = item['type']
      next unless ['movie', 'show'].include?(type)
      title = item[type[0...-1]]['title']
      folders = Utils.search_folder(folder, {'regex' => '.*' + Utils.regexify(title.gsub(/(\w*)\(\d+\)/, '\1')).gsub(/^[Tt]he /, '') + '.*',
                                             'maxdepth' => 1, 'includedir' => 1, 'return_first' => 1})
      file = folders.first
      if file
        list_size += Utils.get_disk_size(file[0])
        list_paths << file[0]
      end
    end
    return list_size, list_paths
  rescue => e
    Speaker.tell_error(e, "Library.get_media_list_size")
    return 0, []
  end

  def self.parse_watch_list(type = 'trakt')
    case type
      when 'imdb'
        Imdb::Watchlist.new($config['imdb']['user'], $config['imdb']['list'])
      when 'trakt'
        TraktList.list('watchlist', 'movies')
    end
  end

  def self.process_search_list(dest_folder:, source: 'trakt', no_prompt: 0, type: 'trakt', extra_keywords: '')
    self.parse_watch_list(source).each do |item|
      movie = item['movie']
      next if movie.nil? || movie['year'].nil? || Time.now.year < movie['year']
      break if break_processing(no_prompt)
      if Speaker.ask_if_needed("Do you want to look for releases of movie #{movie['title']}? (y/n)", no_prompt, 'y') != 'y'
        @refusal += 1
        next
      else
        @refusal == 0
      end
      self.duplicate_search(dest_folder, movie['title'], nil, no_prompt, type)
      found = TorrentSearch.search(keyword: movie['title'] + ' ' + movie['year'] + ' ' + extra_keywords, limit: 10, category: 'movies', no_prompt: no_prompt, filter_dead: 1, move_completed: dest_folder, rename_main: movie['title'], main_only: 1)
      TraktList.remove_from_list([movie], 'watchlist', 'movies') if found
    end
  rescue => e
    Speaker.tell_error(e, "Library.process_search_list")
  end

  def self.replace_movies(folder:, imdb_name_check: 1, filter_criteria: {}, extra_keywords: '', no_prompt: 0)
    $move_completed_torrent = folder
    Utils.search_folder(folder, filter_criteria).each do |film|
      next if File.basename(folder) == film[1]
      title = film[1]
      path = film[0]
      next if Speaker.ask_if_needed("Replace #{title} (file is #{File.basename(path)}? (y/n)", no_prompt) != 'y'
      found = true
      if imdb_name_check.to_i > 0
        title, found = MediaInfo.moviedb_search(title)
        #Look for duplicate
        self.duplicate_search(folder, title, film[1], no_prompt, 'movies') if found
      end
      Speaker.speak_up("Looking for torrent of film #{title}") unless no_prompt > 0 && !found
      replaced = no_prompt > 0 && !found ? false : TorrentSearch.search(title + ' ' + extra_keywords, 10, 'movies', no_prompt, 1, folder, title, true)
      FileUtils.rm_r(File.dirname(path)) if replaced
    end
  rescue => e
    Speaker.tell_error(e, "Library.replace_movies")
  end

end
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

  def self.copy_media_from_list(source_list:, dest_folder:, source_folders: {}, bandwith_limit: 0, no_prompt: 0)
    source_folders = eval(source_folders) if source_folders.is_a?(String)
    source_folders = {} if source_folders.nil?
    return Speaker.speak_up("Invalid destination folder") if dest_folder.nil? || dest_folder == '' || !File.exist?(dest_folder)
    complete_list = TraktList.list(source_list, '')
    return Speaker.speak_up("Empty list #{source_list}") if complete_list.empty?
    abort = 0
    list = TraktList.parse_custom_list(complete_list)
    list.each do |type, _|
      source_folders[type] = Speaker.ask_if_needed("What is the source folder for #{type} media?") if source_folders[type].nil? || source_folders[type] == ''
      dest_type = "#{dest_folder}/#{type.titleize}/"
      list_size, _ = get_media_list_size(list: complete_list, folder: source_folders)
      _, total_space = Utils.get_disk_space(dest_folder)
      while total_space <= list_size
        if Speaker.ask_if_needed("There is not enough space available on #{File.basename(dest_folder)}. You need an additional #{((list_size-total_space).to_d/1024/1024/1024).round(2)} GB to copy the list. Do you want to edit the list now (y/n)?", no_prompt, 'n') != 'y'
          abort = 1
          break
        end
        create_custom_list(source_list, '', source_list)
        list_size, _ = get_media_list_size(list: complete_list, folder: source_folders)
      end
      return Speaker.speak_up("Not enough disk space, aborting...") if abort > 0
      return if Speaker.ask_if_needed("WARNING: All your disk #{dest_folder} will be replaced by the media from your list #{source_list}! Are you sure you want to proceed? (y/n)", no_prompt, 'y') != 'y'
      _, paths = get_media_list_size(list: complete_list, folder: source_folders, type_filter: type)
      Speaker.speak_up 'Deleting extra media...'
      Utils.search_folder(dest_folder, {'includedir' => 1}).sort_by { |x| -x[0].length }.each do |p|
        FileUtils.rm_r(p[0]) unless Utils.is_in_path(paths.map { |i| i.gsub(source_folders[type], dest_type) }, p[0])
      end
      Dir.mkdir(dest_type) unless File.exist?(dest_type)
      Speaker.speak_up('Syncing new media...')
      paths.each do |p|
        final_path = p.gsub("#{source_folders[type]}/", dest_type)
        FileUtils.mkdir_p(File.dirname(final_path)) unless File.exist?(File.dirname(final_path))
        Rsync.run("'#{p}'/", "'#{final_path}'", ['--update', '--times', '--delete', '--recursive', '--verbose', "--bwlimit=#{bandwith_limit}"]) do |result|
          if result.success?
            result.changes.each do |change|
              Speaker.speak_up "#{change.filename} (#{change.summary})"
            end
          else
            Speaker.speak_up result.error
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
    to_delete = {}
    if dest_list
      Speaker.speak_up("List #{name} exists")
      existing = TraktList.list(name)
      to_delete = TraktList.parse_custom_list(existing)
    else
      Speaker.speak_up("List #{name} doesn't exist, creating it...")
      TraktList.create_list(name, description)
    end
    Speaker.speak_up("Ok, we have added #{(new_list['movies'].length + new_list['shows'].length)} items from #{origin}, let's chose what to include in the new list #{name}.")
    ['movies', 'shows'].each do |type|
      t_criteria = criteria[type] || {}
      if (t_criteria['noadd'] && t_criteria['noadd'].to_i > 0) || Speaker.ask_if_needed("Do you want to add #{type} items? (y/n)", t_criteria.empty? ? 0 : 1, 'y') != 'y'
        new_list.delete(type)
        new_list[type] = to_delete[type] if t_criteria['add_only'].to_i > 0 && to_delete && to_delete[type]
        next
      end
      folder = Speaker.ask_if_needed("What is the path of your folder where #{type} are stored? (in full)", t_criteria['folder'].nil? ? 0 : 1, t_criteria['folder'])
      (type == 'shows' ? ['entirely_watched', 'partially_watched', 'ended', 'not_ended'] : ['watched']).each do |cr|
        if (t_criteria[cr] && t_criteria[cr].to_i == 0) || Speaker.ask_if_needed("Do you want to add #{type} #{cr.gsub('_',' ')}? (y/n)", t_criteria[cr].nil? ? 0 : 1, 'y') != 'y'
          new_list[type] = TraktList.filter_trakt_list(new_list[type], type, cr, t_criteria['include'], t_criteria['add_only'], to_delete[type])
        end
      end
      if type =='movies'
        ['released_before','released_after','days_older','days_newer'].each do |cr|
          if t_criteria[cr].to_i != 0 || Speaker.ask_if_needed("Enter the value to keep only #{type} #{cr.gsub('_',' ')}: (empty to not use this filter)", t_criteria[cr].nil? ? 0 : 1, t_criteria[cr]) != ''
            new_list[type] = TraktList.filter_trakt_list(new_list[type], type, cr, t_criteria['include'], t_criteria['add_only'], to_delete[type], t_criteria[cr], folder)
          end
        end
      end
      if t_criteria['review'] || Speaker.ask_if_needed("Do you want to review #{type} individually? (y/n)") == 'y'
        review_cr = t_criteria['review'] || {}
        new_list[type].reverse_each do |item|
          title = item[type[0...-1]]['title']
          year = item[type[0...-1]]['year']
          title = "#{title} (#{year})" if year.to_i > 0 && type == 'movies'
          folders = Utils.search_folder(folder, {'regex' => Utils.title_match_string(title), 'maxdepth' => (type == 'shows' ? 1 : nil), 'includedir' => 1, 'return_first' => 1})
          file = folders.first
          size = file ? Utils.get_disk_size(file[0]) : 0
          if !file && (review_cr['remove_deleted'].to_i > 0 || Speaker.ask_if_needed("No folder found for #{title}, do you want to delete the item from the list? (y/n)", review_cr['remove_deleted'].nil? ? 0 : 1, 'n') == 'y')
            new_list[type].delete(item)
            next
          end
          if (t_criteria['add_only'].to_i == 0 || !TraktList.search_list(type[0...-1], item, to_delete[type])) && (t_criteria['include'].nil? || !t_criteria['include'].include?(title)) && Speaker.ask_if_needed("Do you want to add #{type} '#{title}' (disk size #{(size.to_d/1024/1024/1024).round(2)} GB) to the list (y/n)", review_cr['add_all'].to_i, 'y') != 'y'
            new_list[type].delete(item)
            next
          end
          if type == 'shows' && (review_cr['add_all'].to_i == 0 || review_cr['no_season'].to_i > 0) && ((review_cr['add_all'].to_i == 0 &&
              review_cr['no_season'].to_i > 0) || Speaker.ask_if_needed("Do you want to keep all seasons of #{title}? (y/n)", review_cr['no_season'].to_i, 'n') != 'y')
            choice = Speaker.ask_if_needed("Which seasons do you want to keep? (spearated by comma, like this: '1,2,3', empty for none", review_cr['no_season'].to_i, '').split(',')
            if choice.empty?
              item['seasons'] = nil
            else
              item['seasons'].select! { |s| choice.map! { |n| n.to_i }.include?(s['number']) }
            end
          end
        end
      end
      new_list[type].map! do |i|
        i[type[0...-1]]['seasons'] = i['seasons'].map { |s| s.select { |k, _| k != 'episodes' } } if i['seasons']
        i[type[0...-1]]
      end
      Speaker.speak_up('Update items in the list...')
      TraktList.remove_from_list(to_delete[type], name, type) unless to_delete.nil? || to_delete.empty? || to_delete[type].nil? || to_delete[type].empty?
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

  def self.fetch_media_box(local_folder:, remote_user:, remote_server:, remote_folder:, move_if_finished: [], clean_remote_folder: [], bandwith_limit: 0, active_hours: [], ssh_opts: {})
    loop do
      if Utils.check_if_inactive(active_hours)
        #Speaker.speak_up('Outside of active hours, waiting...')
        sleep 30
        next
      end
      $email_msg = ''
      exit_status = nil
      while exit_status.nil? && !Utils.check_if_inactive(active_hours)
        fetcher = Thread.new {fetch_media_box_core(local_folder, remote_user, remote_server, remote_folder, move_if_finished, clean_remote_folder, bandwith_limit, ssh_opts)}
        while fetcher.alive?
          if Utils.check_if_inactive(active_hours)
            Speaker.speak_up('Active hours finished, terminating current synchronisation')
            `pgrep -f 'rsync' | xargs kill -15`
          end
          sleep 30
        end
        exit_status = fetcher.status
      end
      Report.deliver(object_s: $action + ' - ' + Time.now.strftime("%a %d %b %Y").to_s) if $email && $action
      $email_msg = ''
      sleep 3600 unless exit_status.nil?
    end
  end

  def self.fetch_media_box_core(local_folder, remote_user, remote_server, remote_folder, move_if_finished = [], clean_remote_folder = [], bandwith_limit = 0, ssh_opts = {})
    remote_box = "#{remote_user}@#{remote_server}:#{remote_folder}"
    rsynced_clean = false
    Speaker.speak_up("Starting media synchronisation with #{remote_box} - #{Time.now.utc}")
    Rsync.run("#{remote_box}/", "#{local_folder}", ['--verbose', '--progress', '--recursive', '--acls', '--times', '--remove-source-files', '--human-readable', "--bwlimit=#{bandwith_limit}"]) do |result|
      if result.success?
        rsynced_clean = true
        result.changes.each do |change|
          Speaker.speak_up "#{change.filename} (#{change.summary})"
        end
      else
        Speaker.speak_up result.error
      end
    end
    if rsynced_clean && move_if_finished && move_if_finished.is_a?(Array)
      move_if_finished.each do |m|
        next unless m.is_a?(Array)
        Speaker.speak_up("Moving #{m[0]} folder to #{m[1]}")
        FileUtils.mv(Dir.glob("#{m[0]}/*"), m[1])
      end
    end
    if rsynced_clean && clean_remote_folder && clean_remote_folder.is_a?(Array)
      clean_remote_folder.each do |c|
        Speaker.speak_up("Cleaning folder #{c} on #{remote_server}")
        Net::SSH.start(remote_server, remote_user, ssh_opts) do |ssh|
          ssh.exec!('find ' + c.to_s + ' -type d -empty -exec rmdir "{}" \;')
        end
      end
    end
    compare_remote_files(path: local_folder, remote_server: remote_server, remote_user: remote_user, filter_criteria: {'days_newer' => 10}, ssh_opts: ssh_opts, no_prompt: 1) unless rsynced_clean
    Speaker.speak_up("Finished media box synchronisation - #{Time.now.utc}")
    raise "Rsync failure" unless rsynced_clean
  end

  def self.get_media_list_size(list: [], folder: {}, type_filter: '')
    folder = eval(folder) if folder.is_a?(String)
    if list.nil? || list.empty?
      list_name = Speaker.ask_if_needed('Please enter the name of the trakt list you want to know the total disk size of (of medias on your set folder): ')
      list = TraktList.list(list_name, '')
    end
    parsed_media = {}
    list_size = 0
    list_paths = []
    list.each do |item|
      type = item['type'] == 'season' ? 'show' : item['type']
      r_type = item['type']
      next unless ['movie', 'show'].include?(type)
      l_type = type[-1] == 's' ? type : "#{type}s"
      next if type_filter && type_filter != '' && type_filter != l_type
      parsed_media[l_type] = {} unless parsed_media[l_type]
      folder[l_type] = Speaker.ask_if_needed("Enter the path of the folder where your #{type}s media are stored: ") if folder[l_type].nil? || folder[l_type] == ''
      title = item[type]['title']
      next if parsed_media[l_type][title] && r_type != 'season'
      folders = Utils.search_folder(folder[l_type], {'regex' => Utils.title_match_string(title), 'maxdepth' => (type == 'show' ? 1 : nil), 'includedir' => 1, 'return_first' => 1})
      file = folders.first
      if file
        if r_type == 'season'
          season = item[r_type]['number'].to_s
          s_file = Utils.search_folder(file[0], {'regex' => "season.#{season}", 'maxdepth' => 1, 'includedir' => 1, 'return_first' => 1}).first
          if s_file
            list_size += Utils.get_disk_size(s_file[0])
            list_paths << s_file[0]
          end
        else
          list_size += Utils.get_disk_size(file[0])
          list_paths << file[0]
        end
      else
        Speaker.speak_up("#{title} NOT FOUND in #{folder[l_type]}")
      end
      parsed_media[l_type][title] = item[type]
    end
    Speaker.speak_up("The total disk size of this list is #{list_size/1024/1024/1024} GB")
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
      found = TorrentSearch.search(keywords: movie['title'] + ' ' + movie['year'] + ' ' + extra_keywords, limit: 10, category: 'movies', no_prompt: no_prompt, filter_dead: 1, move_completed: dest_folder, rename_main: movie['title'], main_only: 1)
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
      next if Speaker.ask_if_needed("Replace #{title} (file is #{File.basename(path)})? (y/n)", no_prompt) != 'y'
      found = true
      if imdb_name_check.to_i > 0
        title, found = MediaInfo.moviedb_search(title)
        #Look for duplicate
        self.duplicate_search(folder, title, film[1], no_prompt, 'movies') if found
      end
      Speaker.speak_up("Looking for torrent of film #{title}") unless no_prompt > 0 && !found
      replaced = no_prompt > 0 && !found ? false : TorrentSearch.search(keywords: title + ' ' + extra_keywords, limit: 10, category: 'movies', no_prompt: no_prompt, filter_dead: 1, move_completed: folder, rename_main: title, main_only: true)
      FileUtils.rm_r(File.dirname(path)) if replaced
    end
  rescue => e
    Speaker.tell_error(e, "Library.replace_movies")
  end

end
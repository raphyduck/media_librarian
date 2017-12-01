class Library

  @refusal = 0
  @media_list = Vash.new

  def self.break_processing(no_prompt = 0, threshold = 3)
    if @refusal > threshold
      @refusal = 0
      return $speaker.ask_if_needed("Do you want to stop processing the list now? (y/n)", no_prompt, 'n') == 'y'
    end
    false
  end

  def self.skip_loop_item(question, no_prompt = 0)
    if $speaker.ask_if_needed(question, no_prompt) != 'y'
      @refusal += 1
      return 1
    else
      @refusal == 0
      return 0
    end
  end

  def self.compare_remote_files(path:, remote_server:, remote_user:, filter_criteria: {}, ssh_opts: {}, no_prompt: 0)
    $speaker.speak_up("Starting cleaning remote files on #{remote_user}@#{remote_server}:#{path} using criteria #{filter_criteria}, no_prompt=#{no_prompt}")
    ssh_opts = Utils.recursive_symbolize_keys(ssh_opts)
    ssh_opts = {} if ssh_opts.nil?
    tries = 10
    list = FileTest.directory?(path) ? Utils.search_folder(path, filter_criteria) : [[path, '']]
    list.each do |f|
      begin
        f_path = f[0]
        $speaker.speak_up("Comparing #{f_path} on local and remote #{remote_server}")
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
        $speaker.speak_up("Local md5sum is #{local_md5sum}")
        $speaker.speak_up("Remote md5sum is #{remote_md5sum}")
        if local_md5sum != remote_md5sum || local_md5sum == '' || remote_md5sum == ''
          $speaker.speak_up("Mismatch between the 2 files, the remote file might not exist or the local file is incorrectly downloaded")
          if local_md5sum != '' && remote_md5sum != '' && $speaker.ask_if_needed("Delete the local file? (y/n)", no_prompt, 'n') == 'y'
            Utils.file_rm_r(f_path)
          end
        else
          $speaker.speak_up("The 2 files are identical!")
          if $speaker.ask_if_needed("Delete the remote file? (y/n)", no_prompt, 'y') == 'y'
            Net::SSH.start(remote_server, remote_user, ssh_opts) do |ssh|
              ssh.exec!("rm \"#{f_path}\"")
            end
          end
        end
      rescue => e
        $speaker.tell_error(e, "Library.compare_remote_files - file #{f[0]}")
        retry if (tries -= 1) > 0
      end
    end
  end

  def self.copy_media_from_list(source_list:, dest_folder:, source_folders: {}, bandwith_limit: 0, no_prompt: 0)
    source_folders = {} if source_folders.nil?
    return $speaker.speak_up("Invalid destination folder") if dest_folder.nil? || dest_folder == '' || !File.exist?(dest_folder)
    complete_list = TraktList.list(source_list, '')
    return $speaker.speak_up("Empty list #{source_list}", 0) if complete_list.empty?
    abort = 0
    list = TraktList.parse_custom_list(complete_list)
    list.each do |type, _|
      source_folders[type] = $speaker.ask_if_needed("What is the source folder for #{type} media?") if source_folders[type].nil? || source_folders[type] == ''
      dest_type = "#{dest_folder}/#{type.titleize}/"
      list_size, _ = get_media_list_size(list: complete_list, folder: source_folders)
      _, total_space = Utils.get_disk_space(dest_folder)
      while total_space <= list_size
        $speaker.speak_up "There is not enough space available on #{File.basename(dest_folder)}. You need an additional #{((list_size-total_space).to_d/1024/1024/1024).round(2)} GB to copy the list"
        if $speaker.ask_if_needed("Do you want to edit the list now (y/n)?", no_prompt, 'n') != 'y'
          abort = 1
          break
        end
        create_custom_list(source_list, '', source_list)
        list_size, _ = get_media_list_size(list: complete_list, folder: source_folders)
      end
      return $speaker.speak_up("Not enough disk space, aborting...") if abort > 0
      return if $speaker.ask_if_needed("WARNING: All your disk #{dest_folder} will be replaced by the media from your list #{source_list}! Are you sure you want to proceed? (y/n)", no_prompt, 'y') != 'y'
      _, paths = get_media_list_size(list: complete_list, folder: source_folders, type_filter: type)
      $speaker.speak_up('Deleting extra media...', 0)
      Utils.search_folder(dest_type, {'includedir' => 1}).sort_by { |x| -x[0].length }.each do |p|
        Utils.file_rm_r(p[0]) unless Utils.is_in_path(paths.map { |i| i.gsub(source_folders[type], dest_type) }, p[0])
      end
      Utils.file_mkdir(dest_type) unless File.exist?(dest_type)
      $speaker.speak_up('Syncing new media...', 0)
      paths.each do |p|
        final_path = p.gsub("#{source_folders[type]}/", dest_type)
        Utils.file_mkdir_p(File.dirname(final_path)) unless File.exist?(File.dirname(final_path))
        Rsync.run("'#{p}'/", "'#{final_path}'", ['--update', '--times', '--delete', '--recursive', '--verbose', "--bwlimit=#{bandwith_limit}"]) do |result|
          if result.success?
            result.changes.each do |change|
              $speaker.speak_up "#{change.filename} (#{change.summary})"
            end
          else
            $speaker.speak_up result.error
          end
        end
      end
    end
    $speaker.speak_up("Finished copying media from #{source_list}!", 0)
  end

  def self.copy_trakt_list(name:, description:, origin: 'collection', criteria: {})
    $speaker.speak_up("Fetching items from #{origin}...")
    new_list = {}
    (criteria['types'] || []).each do |t|
      new_list[t] = TraktList.list(origin, t)
    end
    existing_lists = TraktList.list('lists')
    dest_list = existing_lists.select { |l| l['name'] == name }.first
    to_delete = {}
    if dest_list
      $speaker.speak_up("List #{name} exists")
      existing = TraktList.list(name)
      to_delete = TraktList.parse_custom_list(existing)
    else
      $speaker.speak_up("List #{name} doesn't exist, creating it...")
      TraktList.create_list(name, description)
    end
    ['movies', 'shows', 'episodes'].each do |type|
      TraktList.remove_from_list(to_delete[type], name, type) unless to_delete.nil? || to_delete.empty? || to_delete[type].nil? || to_delete[type].empty?
      TraktList.add_to_list(new_list[type], 'custom', name, type) if new_list[type]
    end
  end

  def self.create_custom_list(name:, description:, origin: 'collection', criteria: {})
    $speaker.speak_up("Fetching items from #{origin}...")
    new_list = {
        'movies' => TraktList.list(origin, 'movies'),
        'shows' => TraktList.list(origin, 'shows')
    }
    existing_lists = TraktList.list('lists')
    dest_list = existing_lists.select { |l| l['name'] == name }.first
    to_delete = {}
    if dest_list
      $speaker.speak_up("List #{name} exists")
      existing = TraktList.list(name)
      to_delete = TraktList.parse_custom_list(existing)
    else
      $speaker.speak_up("List #{name} doesn't exist, creating it...")
      TraktList.create_list(name, description)
    end
    $speaker.speak_up("Ok, we have added #{(new_list['movies'].length + new_list['shows'].length)} items from #{origin}, let's chose what to include in the new list #{name}.")
    ['movies', 'shows'].each do |type|
      t_criteria = criteria[type] || {}
      if (t_criteria['noadd'] && t_criteria['noadd'].to_i > 0) || $speaker.ask_if_needed("Do you want to add #{type} items? (y/n)", t_criteria.empty? ? 0 : 1, 'y') != 'y'
        new_list.delete(type)
        new_list[type] = to_delete[type] if t_criteria['add_only'].to_i > 0 && to_delete && to_delete[type]
        next
      end
      folder = $speaker.ask_if_needed("What is the path of your folder where #{type} are stored? (in full)", t_criteria['folder'].nil? ? 0 : 1, t_criteria['folder'])
      (type == 'shows' ? ['entirely_watched', 'partially_watched', 'ended', 'not_ended'] : ['watched']).each do |cr|
        if (t_criteria[cr] && t_criteria[cr].to_i == 0) || $speaker.ask_if_needed("Do you want to add #{type} #{cr.gsub('_', ' ')}? (y/n)", t_criteria[cr].nil? ? 0 : 1, 'y') != 'y'
          new_list[type] = TraktList.filter_trakt_list(new_list[type], type, cr, t_criteria['include'], t_criteria['add_only'], to_delete[type])
        end
      end
      if type =='movies'
        ['released_before', 'released_after', 'days_older', 'days_newer'].each do |cr|
          if t_criteria[cr].to_i != 0 || $speaker.ask_if_needed("Enter the value to keep only #{type} #{cr.gsub('_', ' ')}: (empty to not use this filter)", t_criteria[cr].nil? ? 0 : 1, t_criteria[cr]) != ''
            new_list[type] = TraktList.filter_trakt_list(new_list[type], type, cr, t_criteria['include'], t_criteria['add_only'], to_delete[type], t_criteria[cr], folder)
          end
        end
      end
      if t_criteria['review'] || $speaker.ask_if_needed("Do you want to review #{type} individually? (y/n)") == 'y'
        review_cr = t_criteria['review'] || {}
        sizes = {}
        $speaker.speak_up('Preparing list of files to review...')
        new_list[type].reverse_each do |item|
          title = item[type[0...-1]]['title']
          year = item[type[0...-1]]['year']
          title = "#{title} (#{year})" if year.to_i > 0 && type == 'movies'
          folders = Utils.search_folder(folder, {'regex' => Utils.title_match_string(title), 'maxdepth' => (type == 'shows' ? 1 : nil), 'includedir' => 1, 'return_first' => 1})
          file = folders.first
          sizes["#{title.to_s}#{year.to_s}"] = file ? Utils.get_disk_size(file[0]) : -1
          print '.'
        end
        new_list[type].reverse_each do |item|
          title = item[type[0...-1]]['title']
          year = item[type[0...-1]]['year']
          title = "#{title} (#{year})" if year.to_i > 0 && type == 'movies'
          if sizes["#{title.to_s}#{year.to_s}"].to_d < 0 && (review_cr['remove_deleted'].to_i > 0 || $speaker.ask_if_needed("No folder found for #{title}, do you want to delete the item from the list? (y/n)", review_cr['remove_deleted'].nil? ? 0 : 1, 'n') == 'y')
            new_list[type].delete(item)
            next
          end
          if (t_criteria['add_only'].to_i == 0 || !TraktList.search_list(type[0...-1], item, to_delete[type])) && (t_criteria['include'].nil? || !t_criteria['include'].include?(title)) && $speaker.ask_if_needed("Do you want to add #{type} '#{title}' (disk size #{[(sizes["#{title.to_s}#{year.to_s}"].to_d/1024/1024/1024).round(2), 0].max} GB) to the list (y/n)", review_cr['add_all'].to_i, 'y') != 'y'
            new_list[type].delete(item)
            next
          end
          if type == 'shows' && (review_cr['add_all'].to_i == 0 || review_cr['no_season'].to_i > 0) && ((review_cr['add_all'].to_i == 0 &&
              review_cr['no_season'].to_i > 0) || $speaker.ask_if_needed("Do you want to keep all seasons of #{title}? (y/n)", review_cr['no_season'].to_i, 'n') != 'y')
            choice = $speaker.ask_if_needed("Which seasons do you want to keep? (separated by comma, like this: '1,2,3', empty for none", review_cr['no_season'].to_i, '').split(',')
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
      $speaker.speak_up('Updating items in the list...')
      TraktList.remove_from_list(to_delete[type], name, type) unless to_delete.nil? || to_delete.empty? || to_delete[type].nil? || to_delete[type].empty? || t_criteria['add_only'].to_i > 0
      TraktList.add_to_list(new_list[type], 'custom', name, type)
    end
    $speaker.speak_up("List #{name} is up to date!")
  end

  def self.fetch_media_box(local_folder:, remote_user:, remote_server:, remote_folder:, clean_remote_folder: [], bandwith_limit: 0, active_hours: {}, ssh_opts: {}, exclude_folders_in_check: [], monitor_options: {})
    loop do
      unless Utils.check_if_active(active_hours)
        sleep 30
        next
      end
      exit_status = nil
      low_b = 0
      while exit_status.nil? && Utils.check_if_active(active_hours)
        fetcher = Librarian.burst_thread { fetch_media_box_core(local_folder, remote_user, remote_server, remote_folder, clean_remote_folder, bandwith_limit, ssh_opts, active_hours, exclude_folders_in_check) }
        while fetcher.alive?
          if !Utils.check_if_active(active_hours) || low_b > 24
            $speaker.speak_up('Bandwidth too low, restarting the synchronisation') if low_b > 24
            `pgrep -f 'rsync' | xargs kill -15`
            low_b = 0
          end
          if monitor_options.is_a?(Hash) && monitor_options['network_card'].to_s != '' && bandwith_limit > 0
            in_speed, _ = Utils.get_traffic(monitor_options['network_card'])
            if in_speed < bandwith_limit / 4
              low_b += 1
            else
              low_b = 0
            end
          end
          sleep 10
        end
        exit_status = fetcher.status
        Daemon.merge_notifications(fetcher)
      end
      sleep 3600 unless exit_status.nil?
    end
  end

  def self.fetch_media_box_core(local_folder, remote_user, remote_server, remote_folder, clean_remote_folder = [], bandwith_limit = 0, ssh_opts = {}, active_hours = {}, exclude_folders = [])
    remote_box = "#{remote_user}@#{remote_server}:#{remote_folder}"
    rsynced_clean = false
    $speaker.speak_up("Starting media synchronisation with #{remote_box} - #{Time.now.utc}")
    return $speaker.speak_up("Would run synchonisation") if Env.pretend?
    base_opts = ['--verbose', '--recursive', '--acls', '--times', '--remove-source-files', '--human-readable', "--bwlimit=#{bandwith_limit}"]
    opts = base_opts + ["--partial-dir=#{local_folder}/.rsync-partial"]
    $speaker.speak_up("Running the command: rsync #{opts.join(' ')} #{remote_box}/ #{local_folder}") if Env.debug?
    Rsync.run("#{remote_box}/", "#{local_folder}", opts, ssh_opts['port'], ssh_opts['keys']) do |result|
      result.changes.each do |change|
        $speaker.speak_up "#{change.filename} (#{change.summary})"
      end
      if result.success?
        rsynced_clean = true
      else
        $speaker.speak_up result.error
      end
    end
    if rsynced_clean && clean_remote_folder && clean_remote_folder.is_a?(Array)
      clean_remote_folder.each do |c|
        $speaker.speak_up("Cleaning folder #{c} on #{remote_server}")
        Net::SSH.start(remote_server, remote_user, Utils.recursive_symbolize_keys(ssh_opts)) do |ssh|
          ssh.exec!('find ' + c.to_s + ' -type d -empty -exec rmdir "{}" \;')
        end
      end
    end
    compare_remote_files(path: local_folder, remote_server: remote_server, remote_user: remote_user, filter_criteria: {'days_newer' => 10, 'exclude_path' => exclude_folders}, ssh_opts: ssh_opts, no_prompt: 1) unless rsynced_clean || Utils.check_if_active(active_hours)
    $speaker.speak_up("Finished media box synchronisation - #{Time.now.utc}")
    raise "Rsync failure" unless rsynced_clean
  end

  def self.get_duplicates(medium, threshold = 2)
    return [] if medium.nil? || medium[:files].nil?
    dup_files = medium[:files].select { |x| x[:type].to_s == 'file' }.group_by { |a| a[:parts].join }.select { |_, v| v.count >= threshold }.map { |_, v| v }.flatten
    return [] if dup_files.count < threshold
    dups_files = dup_files.select { |x| x[:type].to_s == 'file' && File.exists?(x[:name]) } #You never know...
    return [] unless dups_files.count >= threshold
    dups_files = MediaInfo.sort_media_files(dups_files)
    dups_files
  end

  def self.get_media_list_size(list: [], folder: {}, type_filter: '')
    if list.nil? || list.empty?
      list_name = $speaker.ask_if_needed('Please enter the name of the trakt list you want to know the total disk size of (of medias on your set folder): ')
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
      folder[l_type] = $speaker.ask_if_needed("Enter the path of the folder where your #{type}s media are stored: ") if folder[l_type].nil? || folder[l_type] == ''
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
        $speaker.speak_up("#{title} NOT FOUND in #{folder[l_type]}")
      end
      parsed_media[l_type][title] = item[type]
    end
    $speaker.speak_up("The total disk size of this list is #{list_size/1024/1024/1024} GB")
    return list_size, list_paths
  rescue => e
    $speaker.tell_error(e, "Library.get_media_list_size")
    return 0, []
  end

  def self.handle_completed_download(torrent_path:, torrent_name:, completed_folder:, destination_folder:, handling: {}, remove_duplicates: 0, folder_hierarchy: {})
    full_p = torrent_path + '/' + torrent_name
    if FileTest.directory?(full_p)
      handled_files = (!handling['file_types'].nil? && handling['file_types'].is_a?(Array)) ? handling['file_types'] + ['rar', 'zip'] : ['rar', 'zip']
      Utils.search_folder(full_p, {'regex' => Regexp.new('.*\.(' + handled_files.join('|') + '$)').to_s}).each do |f|
        handle_completed_download(torrent_path: File.dirname(f[0]), torrent_name: File.basename(f[0]), completed_folder: completed_folder, destination_folder: destination_folder, handling: handling, remove_duplicates: remove_duplicates)
      end
    else
      extension = torrent_name.gsub(/.*\.(\w{2,4}$)/, '\1')
      if ['rar', 'zip'].include?(extension)
        Utils.extract_archive(extension, full_p, torrent_path + '/extracted')
        handle_completed_download(torrent_path: torrent_path, torrent_name: 'extracted', completed_folder: completed_folder, destination_folder: destination_folder, handling: handling, remove_duplicates: remove_duplicates)
        Utils.file_rm_r(torrent_path + '/extracted')
      else
        if handling['file_types']
          type = full_p.gsub(Regexp.new("^#{completed_folder}\/?([a-zA-Z1-9 _-]*)\/.*"), '\1')
          return if File.basename(File.dirname(full_p)).downcase == 'sample' || File.basename(full_p).match(/([\. -])?sample([\. -])?/)
          return if File.stat(full_p).nlink > 1 #File already hard linked elsewhere, moving on
          type.downcase!
          ttype = handling[type] && handling[type]['media_type'] ? handling[type]['media_type'] : 'unknown'
          item_name, item = MediaInfo.identify_title(full_p, ttype, 1, (folder_hierarchy[ttype] || FOLDER_HIERARCHY[ttype]), completed_folder)
          if VALID_VIDEO_MEDIA_TYPE.include?(ttype) && handling[type]['move_to']
            rename_media_file(full_p, handling[type]['move_to'], ttype, item_name, item, 1, 1, 1, folder_hierarchy)
          else
            #TODO: Handle flac,...
            destination = full_p.gsub(completed_folder, destination_folder)
            Utils.move_file(full_p, destination, 1)
          end
        end
      end
    end
  end

  def self.handle_duplicates(files, remove_duplicates = 0, no_prompt = 0)
    files.each do |id, f|
      dup_files = get_duplicates(f)
      next unless dup_files.count > 0
      $speaker.speak_up("Duplicate files found for #{f[:full_name]}")
      dup_files.each do |d|
        $speaker.speak_up("'#{d[:name]}'")
      end
      if remove_duplicates.to_i > 0
        $speaker.speak_up('Will now remove duplicates')
        dup_files.each do |d|
          next if dup_files.index(d) == 0 && no_prompt.to_i > 0
          if $speaker.ask_if_needed("Remove file #{d[:name]}? (y/n)", no_prompt.to_i, 'y').to_s == 'y'
            Utils.file_rm(d[:name])
            files[id][:files].select! { |x| x[:name].to_s != d[:name] }
          end
        end
      end
    end
    files
  end

  def self.parse_media(file, type, no_prompt = 0, files = {}, folder_hierarchy = {}, rename = {}, file_attrs = {}, base_folder = '', ids = {}, item = nil, item_name = '')
    item_name, item = MediaInfo.identify_title(file[:name], type, no_prompt, (folder_hierarchy[type] || FOLDER_HIERARCHY[type]), base_folder, ids) unless item && item_name.to_s != ''
    unless no_prompt.to_i == 0 || item
      $speaker.speak_up("File #{File.basename(file[:name])} not identified, skipping", 0)
      return files
    end
    unless rename.nil? || rename.empty? || rename['rename_media'].to_i == 0 || file[:type].to_s != 'file'
      f_path = rename_media_file(file[:name],
                                 (rename['destination'] && rename['destination'][type] ? rename['destination'][type] : DEFAULT_MEDIA_DESTINATION[type]),
                                 type,
                                 item_name,
                                 item,
                                 no_prompt,
                                 0,
                                 0,
                                 folder_hierarchy,
      )
      file[:name] = f_path unless f_path == ''
    end
    full_name, identifiers, info = MediaInfo.parse_media_filename(
        file[:name],
        type,
        item,
        item_name,
        no_prompt,
        folder_hierarchy,
        base_folder,
        file
    )
    return files if identifiers.empty? || full_name == ''
    $speaker.speak_up("Adding #{file[:type]} #{full_name} to list", 0) if Env.debug?
    file = nil unless file[:type].to_s != 'file' || File.exists?(file[:name])
    files = MediaInfo.media_add(item_name,
                                type,
                                full_name,
                                identifiers,
                                info,
                                file_attrs,
                                file,
                                files
    )
    files
  end

  def self.process_filter_sources(source_type:, source:, category:, no_prompt: 0, destination: {})
    return $speaker.speak_up("Invalid source") if source.nil? || source.empty?
    search_list = {}
    existing_files = {}
    missing = {}
    case source_type
      when 'search'
        keywords = source['keywords']
        keywords = [keywords] if keywords.is_a?(String)
        keywords.each do |keyword|
          search_list = parse_media(
              {:type => 'keyword', :name => keyword},
              category,
              no_prompt,
              search_list,
              {},
              {},
              {:rename_main => source[:rename_main],
               :main_only => source[:main_only].to_i,
               :move_completed => (destination[category] || File.dirname(DEFAULT_MEDIA_DESTINATION[category]))}
          )
        end
      when 'trakt'
        $speaker.speak_up('Parsing trakt list, can take a long time...')
        TraktList.list(source['list_name']).each do |item|
          type = item['type']
          f = item[type]
          type = Utils.regularise_media_type(type)
          next if Time.now.year < (f['year'] || Time.now.year + 3)
          search_list = parse_media({:type => 'trakt', :name => "#{f['title']} (#{f['year']})".gsub('/', ' ')},
                                    type,
                                    no_prompt,
                                    search_list,
                                    {},
                                    {},
                                    {:trakt_obj => f, :trakt_list => source['list_name'], :trakt_type => type},
                                    '',
                                    f['ids']
          )
        end
        search_list.keys.each do |id|
          next if id.is_a?(Symbol)
          ct = search_list[id][:type]
          next if source['existing_folder'][ct].nil?
          existing_files[ct] = process_folder(type: ct, folder: source['existing_folder'][ct], no_prompt: no_prompt, remove_duplicates: 0) unless existing_files[ct]
          case ct
            when 'movies'
              already_exists = get_duplicates(existing_files[ct][id], 1)
              already_exists.each do |ae|
                if $speaker.ask_if_needed("Replace already existing file #{ae[:name]}? (y/n)", no_prompt.to_i, 'y').to_s == 'y'
                  search_list[id][:files] = [] if search_list[id][:files].nil?
                  search_list[id][:files] << ae
                elsif $speaker.ask_if_needed("Remove #{search_list[id][:name]} from the search list? (y/n)", no_prompt.to_i, 'n').to_s == 'y'
                  TraktList.list_cache_add(source['list_name'], ct, search_list[id][:trakt_obj]) if search_list[id][:trakt_obj]
                  search_list.delete(id)
                end
              end
            when 'shows'
              search_list.delete(id)
              missing[ct] = TvSeries.list_missing_episodes(
                  existing_files[ct],
                  no_prompt,
                  (source['delta'] || 10),
                  source['include_specials'],
                  {}
              ) unless missing[ct]
          end
        end
        search_list.merge!(missing['shows']) if missing['shows']
        search_list.keep_if { |f| !f.is_a?(Hash) || f[:type] != 'movies' || (!f[:release_date].nil? && f[:release_date] < Time.now) }
      when 'filesystem'
        return search_list unless source['existing_folder'] && source['existing_folder'][category]
        existing_files = process_folder(type: category, folder: source['existing_folder'][category], no_prompt: no_prompt, filter_criteria: source['filter_criteria'])
        case category
          when 'shows'
            search_list = TvSeries.list_missing_episodes(
                existing_files,
                no_prompt,
                (source['delta'] || 10),
                source['include_specials'],
                search_list
            )
        end
    end
    search_list
  end

  def self.process_folder(type:, folder:, item_name: '', remove_duplicates: 0, rename: {}, filter_criteria: {}, no_prompt: 0, folder_hierarchy: {})
    $speaker.speak_up("Processing folder #{folder}...#{' for ' + item_name.to_s if item_name.to_s != ''}", 0)
    files, raw_filtered, cache_name = nil, [], folder.to_s + type.to_s
    Utils.lock_block(__method__.to_s + cache_name) {
      file_criteria = {'regex' => '.*' + Utils.regexify(item_name.gsub(/(\w*)\(\d+\)/, '\1').strip.gsub(/ /, '.')) + '.*'}
      raw_filtered += Utils.search_folder(folder, filter_criteria.merge(file_criteria)) if filter_criteria && !filter_criteria.empty?
      if @media_list[cache_name].nil? || item_name.to_s != '' || remove_duplicates.to_i > 0 ||
          (filter_criteria && !filter_criteria.empty?) || (rename && !rename.empty?)
        Utils.search_folder(folder, file_criteria).each do |f|
          next unless f[0].match(Regexp.new(VALID_VIDEO_EXT))
          @media_list[cache_name, CACHING_TTL] = parse_media({:type => 'file', :name => f[0]}, type, no_prompt, @media_list[cache_name] || {}, folder_hierarchy, rename, {}, folder)
        end
        @media_list[cache_name, CACHING_TTL] = handle_duplicates(@media_list[cache_name] || {}, remove_duplicates, no_prompt)
      elsif Env.debug?
        $speaker.speak_up "Cache of media_list [#{cache_name}] exists, returning it directly"
      end
    }
    if filter_criteria && !filter_criteria.empty? && !@media_list[cache_name].empty?
      files = @media_list[cache_name]
      files.keep_if { |_, f| !(f[:files] & raw_filtered.flatten).empty? }
    end
    return files || @media_list[cache_name]
  rescue => e
    $speaker.tell_error(e, "Library.process_folder")
    {}
  end

  def self.rename_media_file(original, destination, type, item_name, item, no_prompt = 0, hard_link = 0, replaced_outdated = 0, folder_hierarchy = {})
    metadata = MediaInfo.identify_metadata(original, type, item_name, item, no_prompt, folder_hierarchy)
    destination = Utils.parse_filename_template(destination, metadata)
    return '' if destination.nil?
    destination += ".#{metadata['extension'].downcase}"
    if metadata['is_found']
      if $speaker.ask_if_needed("Move '#{original}' to '#{destination}'?", no_prompt, 'y').to_s == 'y'
        _, destination = Utils.move_file(original, destination, hard_link, replaced_outdated)
      end
    else
      destination = ''
    end
    destination
  end

end
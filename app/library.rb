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
    ssh_opts = Utils.recursive_typify_keys(ssh_opts)
    ssh_opts = {} if ssh_opts.nil?
    tries = 10
    list = FileTest.directory?(path) ? FileUtils.search_folder(path, filter_criteria) : [[path, '']]
    list.each do |f|
      begin
        f_path = f[0]
        $speaker.speak_up("Comparing #{f_path} on local and remote #{remote_server}")
        local_md5sum = FileUtils.md5sum(f_path)
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
            FileUtils.rm_r(f_path)
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

  def self.copy_media_from_list(source_list:, dest_folder:, source_folders: {}, bandwith_limit: 0, no_prompt: 0, continuous: 0)
    source_folders = {} if source_folders.nil?
    return $speaker.speak_up("Invalid destination folder") if dest_folder.nil? || dest_folder == '' || !File.exist?(dest_folder)
    complete_list = TraktAgent.list(source_list, '')
    return $speaker.speak_up("Empty list #{source_list}", 0) if complete_list.empty?
    loop do
      abort = 0
      list = TraktAgent.parse_custom_list(complete_list)
      path_list = {}
      list_size = 0
      list.map { |n, _| n }.uniq.each do |type|
        s, path_list[type] = get_media_list_size(list: complete_list, folder: source_folders, type_filter: type)
        list_size += s
      end
      list.each do |type, _|
        source_folders[type] = $speaker.ask_if_needed("What is the source folder for #{type} media?") if source_folders[type].nil? || source_folders[type] == ''
        dest_type = "#{dest_folder}/#{type.titleize}/"
        _, total_space = FileUtils.get_disk_space(dest_folder)
        while total_space <= list_size
          $speaker.speak_up "There is not enough space available on #{File.basename(dest_folder)}. You need an additional #{((list_size-total_space).to_d/1024/1024/1024).round(2)} GB to copy the list"
          if $speaker.ask_if_needed("Do you want to edit the list now (y/n)?", no_prompt, 'n') != 'y'
            abort = 1
            break
          end
          create_custom_list(source_list, '', source_list)
          list_size, _ = get_media_list_size(list: complete_list, folder: source_folders)
        end
        $speaker.speak_up("Not enough disk space, aborting...") if abort > 0
        abort = 1 if abort == 0 && $speaker.ask_if_needed("WARNING: All your disk #{dest_folder} will be replaced by the media from your list #{source_list}! Are you sure you want to proceed? (y/n)", no_prompt, 'y') != 'y'
        if abort == 0
          $speaker.speak_up("Deleting extra media...", 0)
          FileUtils.search_folder(dest_type).sort_by { |x| -x[0].length }.each do |p|
            if File.exist?(p[0])
              FileUtils.rm_r(p[0]) unless FileUtils.is_in_path(path_list[type].map { |i| StringUtils.clean_search(i).gsub(source_folders[type], dest_type) }, p[0])
            elsif Env.debug?
              $speaker.speak_up "'#{p[0]}' not found, can not delete, skipping"
            end
          end
          FileUtils.mkdir(dest_type) unless File.exist?(dest_type)
          $speaker.speak_up("Syncing new media...", 0)
          path_list[type].each do |p|
            final_path = StringUtils.clean_search(p).gsub("#{source_folders[type]}/", dest_type)
            FileUtils.mkdir_p(File.dirname(final_path)) unless File.exist?(File.dirname(final_path))
            $speaker.speak_up "Syncing '#{p}' to '#{final_path}'" if Env.debug?
            Rsync.run("#{p}/", final_path, ['--update', '--times', '--delete', '--recursive', '--verbose', "--bwlimit=#{bandwith_limit}"]) do |result|
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
      break unless continuous.to_i > 0
      sleep 86400
    end
  end

  def self.copy_trakt_list(name:, description:, origin: 'collection', criteria: {})
    $speaker.speak_up("Fetching items from #{origin}...")
    new_list = {}
    (criteria['types'] || []).each do |t|
      new_list[t] = TraktAgent.list(origin, t)
    end
    existing_lists = TraktAgent.list('lists')
    dest_list = existing_lists.select { |l| l['name'] == name }.first
    to_delete = {}
    if dest_list
      $speaker.speak_up("List #{name} exists")
      existing = TraktAgent.list(name)
      to_delete = TraktAgent.parse_custom_list(existing)
    else
      $speaker.speak_up("List #{name} doesn't exist, creating it...")
      TraktAgent.create_list(name, description)
    end
    ['movies', 'shows', 'episodes'].each do |type|
      TraktAgent.remove_from_list(to_delete[type], name, type) unless to_delete.nil? || to_delete.empty? || to_delete[type].nil? || to_delete[type].empty?
      TraktAgent.add_to_list(new_list[type], name, type) if new_list[type]
    end
  end

  def self.create_custom_list(name:, description:, origin: 'collection', criteria: {}, no_prompt: 0)
    $speaker.speak_up("Fetching items from #{origin}...", 0)
    new_list = {
        'movies' => TraktAgent.list(origin, 'movies'),
        'shows' => TraktAgent.list(origin, 'shows')
    }
    existing_lists = TraktAgent.list('lists')
    dest_list = existing_lists.select { |l| l['name'] == name }.first
    to_delete = {}
    if dest_list
      $speaker.speak_up("List #{name} exists", 0)
      existing = TraktAgent.list(name)
      to_delete = TraktAgent.parse_custom_list(existing)
    else
      $speaker.speak_up("List #{name} doesn't exist, creating it...")
      TraktAgent.create_list(name, description)
    end
    $speaker.speak_up("Ok, we have added #{(new_list['movies'].length + new_list['shows'].length)} items from #{origin}, let's chose what to include in the new list #{name}.", 0)
    ['movies', 'shows'].each do |type|
      t_criteria = criteria[type] || {}
      if (t_criteria['noadd'] && t_criteria['noadd'].to_i > 0) || $speaker.ask_if_needed("Do you want to add #{type} items? (y/n)", no_prompt, 'y') != 'y'
        new_list.delete(type)
        new_list[type] = to_delete[type] if t_criteria['add_only'].to_i > 0 && to_delete && to_delete[type]
        next
      end
      folder = $speaker.ask_if_needed("What is the path of your folder where #{type} are stored? (in full)", t_criteria['folder'].nil? ? 0 : 1, t_criteria['folder'])
      ['released_before', 'released_after', 'days_older', 'days_newer', 'entirely_watched', 'partially_watched',
       'ended', 'not_ended', 'watched'].each do |cr|
        if $speaker.ask_if_needed("Enter the value to keep only #{type} #{cr.gsub('_', ' ')}: (empty to not use this filter)", no_prompt, t_criteria[cr]).to_s != ''
          new_list[type] = TraktAgent.filter_trakt_list(new_list[type], type, cr, t_criteria['include'], t_criteria['add_only'], to_delete[type], t_criteria[cr], folder)
        end
      end
      if t_criteria['review'] || $speaker.ask_if_needed("Do you want to review #{type} individually? (y/n)", no_prompt, 'n') == 'y'
        review_cr = t_criteria['review'] || {}
        $speaker.speak_up('Preparing list of files to review...', 0)
        new_list[type].reverse_each do |item|
          title = item[type[0...-1]]['title']
          year = item[type[0...-1]]['year']
          title = "#{title} (#{year})" if year.to_i > 0 && type == 'movies'
          folders = FileUtils.search_folder(folder, {'regex' => StringUtils.title_match_string(title), 'maxdepth' => (type == 'shows' ? 1 : nil), 'includedir' => 1, 'return_first' => 1})
          file = folders.first
          size = file ? FileUtils.get_disk_size(file[0]) : -1
          if size.to_d < 0 && (review_cr['remove_deleted'].to_i > 0 || $speaker.ask_if_needed("No folder found for #{title}, do you want to delete the item from the list? (y/n)", no_prompt, 'n') == 'y')
            $speaker.speak_up "No folder found for '#{title}', removing from list" if Env.debug?
            new_list[type].delete(item)
            next
          end
          if (t_criteria['add_only'].to_i == 0 || !TraktAgent.search_list(type[0...-1], item, to_delete[type])) && (t_criteria['include'].nil? || !t_criteria['include'].include?(title)) && $speaker.ask_if_needed("Do you want to add #{type} '#{title}' (disk size #{[(size.to_d/1024/1024/1024).round(2), 0].max} GB) to the list (y/n)", review_cr['add_all'].to_i, 'y') != 'y'
            $speaker.speak_up "Removing '#{title}' from list" if Env.debug?
            new_list[type].delete(item)
            next
          end
          if type == 'shows' && (review_cr['add_all'].to_i == 0 || review_cr['no_season'].to_i > 0) && ((review_cr['add_all'].to_i == 0 &&
              review_cr['no_season'].to_i > 0) || $speaker.ask_if_needed("Do you want to keep all seasons of #{title}? (y/n)", no_prompt, 'n') != 'y')
            choice = $speaker.ask_if_needed("Which seasons do you want to keep? (separated by comma, like this: '1,2,3', empty for none", no_prompt, '').split(',')
            if choice.empty?
              item['seasons'] = nil
            else
              item['seasons'].select! { |s| choice.map! { |n| n.to_i }.include?(s['number']) }
            end
          end
          print '.'
        end
      end
      new_list[type].map! do |i|
        i[type[0...-1]]['seasons'] = i['seasons'].map { |s| s.select { |k, _| k != 'episodes' } } if i['seasons']
        i[type[0...-1]]
      end
      $speaker.speak_up('Updating items in the list...', 0)
      TraktAgent.remove_from_list(to_delete[type], name, type) unless to_delete.nil? || to_delete.empty? || to_delete[type].nil? || to_delete[type].empty? || t_criteria['add_only'].to_i > 0
      TraktAgent.add_to_list(new_list[type], name, type)
    end
    $speaker.speak_up("List #{name} is up to date!", 0)
  end

  def self.fetch_media_box(local_folder:, remote_user:, remote_server:, remote_folder:, clean_remote_folder: [], bandwith_limit: 0, active_hours: {}, ssh_opts: {}, exclude_folders_in_check: [], monitor_options: {})
    loop do
      begin
        unless Utils.check_if_active(active_hours)
          sleep 30
          next
        end
        exit_status = nil
        low_b = 0
        while Utils.check_if_active(active_hours) && `ps ax | grep '#{remote_user}@#{remote_server}:#{remote_folder}' | grep -v grep` == ''
          fetcher = Librarian.burst_thread { fetch_media_box_core(local_folder, remote_user, remote_server, remote_folder, clean_remote_folder, bandwith_limit, ssh_opts, active_hours, exclude_folders_in_check) }
          while fetcher.alive?
            if !Utils.check_if_active(active_hours) || low_b > 60
              $speaker.speak_up('Bandwidth too low, restarting the synchronisation') if low_b > 24
              `pgrep -f '#{remote_user}@#{remote_server}:#{remote_folder}' | xargs kill -15`
              low_b = 0
            end
            if monitor_options.is_a?(Hash) && monitor_options['network_card'].to_s != '' && bandwith_limit > 0
              in_speed, _ = Utils.get_traffic(monitor_options['network_card'])
              if in_speed && in_speed < bandwith_limit / 4
                low_b += 1
              else
                low_b = 0
              end
            end
            sleep 10
          end
          exit_status = fetcher.status
          Daemon.merge_notifications(fetcher)
          sleep 3600 unless exit_status.nil?
        end
      rescue => e
        $speaker.tell_error(e, "Library.fetch_media_box")
        sleep 180
      end
    end
  end

  def self.fetch_media_box_core(local_folder, remote_user, remote_server, remote_folder, clean_remote_folder = [], bandwith_limit = 0, ssh_opts = {}, active_hours = {}, exclude_folders = [])
    remote_box = "#{remote_user}@#{remote_server}:#{remote_folder}"
    rsynced_clean = false
    $speaker.speak_up("Starting media synchronisation with #{remote_box} - #{Time.now.utc}", 0)
    return $speaker.speak_up("Would run synchonisation") if Env.pretend?
    base_opts = ['--verbose', '--recursive', '--acls', '--times', '--remove-source-files', '--human-readable', "--bwlimit=#{bandwith_limit}"]
    opts = base_opts + ["--partial-dir=#{local_folder}/.rsync-partial"]
    $speaker.speak_up("Running the command: rsync #{opts.join(' ')} #{remote_box}/ #{local_folder}") if Env.debug?
    Rsync.run("#{remote_box}/", "#{local_folder}", opts, ssh_opts['port'] || 22, ssh_opts['keys']) do |result|
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
        $speaker.speak_up("Cleaning folder #{c} on #{remote_server}", 0) if Env.debug?
        Net::SSH.start(remote_server, remote_user, Utils.recursive_typify_keys(ssh_opts)) do |ssh|
          ssh.exec!('find ' + c.to_s + ' -type d -empty -exec rmdir "{}" \;')
        end
      end
    end
    compare_remote_files(path: local_folder, remote_server: remote_server, remote_user: remote_user, filter_criteria: {'days_newer' => 10, 'exclude_path' => exclude_folders}, ssh_opts: ssh_opts, no_prompt: 1) unless rsynced_clean || Utils.check_if_active(active_hours)
    $speaker.speak_up("Finished media box synchronisation - #{Time.now.utc}", 0)
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
      list = TraktAgent.list(list_name, '')
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
      folder[l_type] = $speaker.ask_if_needed("Enter the path of the folder where your #{type}s media are stored: ") if folder[l_type].to_s == ''
      title = "#{item[type]['title']}#{' (' + item[type]['year'].to_s + ')' if l_type == 'movies' && item[type]['year'].to_i > 0}"
      next if parsed_media[l_type][title] && r_type != 'season'
      folders = FileUtils.search_folder(folder[l_type], {'regex' => StringUtils.title_match_string(title), 'maxdepth' => (type == 'show' ? 1 : nil), 'includedir' => 1, 'return_first' => 1})
      file = folders.first
      if file
        if r_type == 'season'
          season = item[r_type]['number'].to_s
          s_file = FileUtils.search_folder(file[0], {'regex' => "season.#{season}", 'maxdepth' => 1, 'includedir' => 1, 'return_first' => 1}).first
          if s_file
            list_size += FileUtils.get_disk_size(s_file[0]).to_d
            list_paths << s_file[0]
          end
        else
          list_size += FileUtils.get_disk_size(file[0]).to_d
          list_paths << file[0]
        end
      else
        $speaker.speak_up("#{title} NOT FOUND in #{folder[l_type]}")
      end
      parsed_media[l_type][title] = item[type]
    end
    $speaker.speak_up("The total disk size of this list is #{(list_size/1024/1024/1024).round(2)} GB")
    return list_size, list_paths
  rescue => e
    $speaker.tell_error(e, "Library.get_media_list_size")
    return 0, []
  end

  def self.get_search_list(source_type, category, source, no_prompt = 0)
    search_list = {}
    return search_list unless source['existing_folder'] && source['existing_folder'][category]
    case source_type
      when 'filesystem'
        search_list = process_folder(type: category, folder: source['existing_folder'][category], no_prompt: no_prompt, filter_criteria: source['filter_criteria'])
      when 'trakt'
        $speaker.speak_up('Parsing trakt list, can take a long time...', 0)
        TraktAgent.list(source['list_name']).each do |item|
          type = item['type'] rescue next
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
    end
    search_list
  end

  def self.handle_completed_download(torrent_path:, torrent_name:, completed_folder:, destination_folder:, handling: {}, remove_duplicates: 0, folder_hierarchy: {}, force_process: 0, root_process: 1)
    full_p = torrent_path + '/' + torrent_name
    handled = 0
    handled_files = (
    if (!handling['file_types'].nil? && handling['file_types'].is_a?(Array))
      handling['file_types'].map { |o| o.is_a?(Hash) ? o.map { |k, _| k } : o } + ['rar', 'zip']
    else
      ['rar', 'zip']
    end).flatten
    if FileTest.directory?(full_p)
      FileUtils.search_folder(full_p, {'regex' => Regexp.new('.*\.(' + handled_files.join('|') + '$)').to_s}).each do |f|
        handled += handle_completed_download(torrent_path: File.dirname(f[0]), torrent_name: File.basename(f[0]), completed_folder: completed_folder, destination_folder: destination_folder, handling: handling, remove_duplicates: remove_duplicates, root_process: 0)
      end
    else
      $speaker.speak_up "Handling downloaded file '#{full_p}'" if Env.debug?
      extension = torrent_name.gsub(/.*\.(\w{2,4}$)/, '\1')
      if ['rar', 'zip'].include?(extension)
        FileUtils.extract_archive(extension, full_p, torrent_path + '/extracted')
        handled += handle_completed_download(torrent_path: torrent_path, torrent_name: 'extracted', completed_folder: completed_folder, destination_folder: destination_folder, handling: handling, remove_duplicates: remove_duplicates, root_process: 0)
        FileUtils.rm_r(torrent_path + '/extracted')
      elsif handling['file_types']
        if force_process.to_i == 0 && !handled_files.include?(extension)
          $speaker.speak_up "Unsupported extension '#{extension}'"
          return handled
        end
        type = full_p.gsub(Regexp.new("^#{completed_folder}\/?([a-zA-Z1-9 _-]*)\/.*"), '\1')
        args = handling['file_types'].select { |x| x.is_a?(Hash) && x[extension] }.first
        if File.basename(File.dirname(full_p)).downcase == 'sample' || File.basename(full_p).match(/([\. -])?sample([\. -])?/)
          $speaker.speak_up 'File is a sample, skipping...'
          return handled
        end
        if File.stat(full_p).nlink > 1
          $speaker.speak_up 'File is already hard linked, skipping...'
          return handled
        end
        rf = "#{completed_folder}/#{type}"
        type.downcase!
        ttype = handling[type] && handling[type]['media_type'] ? handling[type]['media_type'] : 'unknown'
        item_name, item = MediaInfo.identify_title(full_p, ttype, 1, (folder_hierarchy[ttype] || FOLDER_HIERARCHY[ttype]), completed_folder)
        if args && args['convert_comics'].to_s != ''
          Book.convert_comics(full_p, extension, args['convert_comics'], 1).each do |nf|
            handled += handle_completed_download(torrent_path: File.dirname(nf), torrent_name: File.basename(nf), completed_folder: completed_folder, destination_folder: destination_folder, handling: handling, remove_duplicates: remove_duplicates, force_process: force_process, root_process: 0)
          end
        elsif VALID_VIDEO_MEDIA_TYPE.include?(ttype) && handling[type]['move_to']
          rename_media_file(full_p, handling[type]['move_to'], ttype, item_name, item, 1, 1, 1, folder_hierarchy)
          process_folder(type: ttype, folder: rf, remove_duplicates: 1, no_prompt: 1)
          handled = 1
        else
          #TODO: Handle flac,...
          destination = full_p.gsub(completed_folder, destination_folder)
          FileUtils.move_file(full_p, destination, 1)
          handled = 1
        end
      elsif Env.debug?
        $speaker.speak_up 'File type not handled, skipping...'
      end
    end
    $speaker.speak_up('Could not find any file to handle!') if root_process.to_i > 0 && handled == 0
    handled
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
            FileUtils.rm(d[:name])
            files[id][:files].select! { |x| x[:name].to_s != d[:name] }
          end
        end
      end
    end
    files
  end

  def self.parse_media(file, type, no_prompt = 0, files = {}, folder_hierarchy = {}, rename = {}, file_attrs = {}, base_folder = '', ids = {}, item = nil, item_name = '')
    item_name, item = MediaInfo.identify_title(file[:formalized_name] || file[:name], type, no_prompt, (folder_hierarchy[type] || FOLDER_HIERARCHY[type]), base_folder, ids) unless item && item_name.to_s != ''
    unless (no_prompt.to_i == 0 && item_name.to_s != '') || item
      $speaker.speak_up("File '#{File.basename(file[:name])}' not identified, skipping") if Env.debug?
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
    $speaker.speak_up("Adding #{file[:type]} '#{full_name}' (filename '#{File.basename(file[:name])}') to list", 0) if Env.debug?
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

  def self.process_filter_sources(source_type:, source:, category:, no_prompt: 0, destination: {}, qualities: {})
    if source.nil? || source.empty?
      $speaker.speak_up("Invalid source")
      return {}, {}
    end
    search_list = {}
    existing_files = {}
    missing = {}
    case source_type
      when 'calibre'
        search_list.merge!(BookSeries.subscribe_series(no_prompt)) if source['series'].to_i > 0
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
      when 'filesystem', 'trakt'
        search_list = get_search_list(source_type, category, source, no_prompt)
        search_list.keys.each do |id|
          next if id.is_a?(Symbol)
          ct = search_list[id][:type]
          next if source['existing_folder'].nil? || source['existing_folder'][ct].nil?
          unless existing_files[ct]
            existing_files[ct] = process_folder(type: ct, folder: source['existing_folder'][ct], no_prompt: no_prompt, remove_duplicates: 0)
            existing_files[ct][:shows] = search_list[:shows] if search_list[:shows]
          end
          case ct
            when 'movies'
              search_list[id][:files] = []
              unless source['upgrade'].to_i <= 0 || MediaInfo.qualities_file_filter(existing_files[ct][id], qualities)
                search_list.delete(id)
                next
              end
              already_exists = get_duplicates(existing_files[ct][id], 1)
              already_exists.each do |ae|
                if $speaker.ask_if_needed("Replace already existing file #{ae[:name]}? (y/n)", (no_prompt.to_i * source['upgrade'].to_i), 'y').to_s == 'y'
                  search_list[id][:files] << ae
                elsif $speaker.ask_if_needed("Remove #{search_list[id][:name]} from the search list? (y/n)", (no_prompt.to_i * source['upgrade'].to_i), 'n').to_s == 'y'
                  TraktAgent.list_cache_add(source['list_name'], ct, search_list[id][:trakt_obj]) if search_list[id][:trakt_obj]
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
                  {},
                  source['upgrade'].to_i > 0 ? qualities : {}
              ) unless missing[ct]
          end
        end
        search_list.merge!(missing['shows']) if missing['shows']
        search_list.keep_if { |_, f| !f.is_a?(Hash) || f[:type] != 'movies' || (!f[:release_date].nil? && f[:release_date] < Time.now) }
    end
    return search_list, existing_files
  end

  def self.process_folder(type:, folder:, item_name: '', remove_duplicates: 0, rename: {}, filter_criteria: {}, no_prompt: 0, folder_hierarchy: {}, cache_expiration: CACHING_TTL)
    $speaker.speak_up("Processing folder #{folder}...#{' for ' + item_name.to_s if item_name.to_s != ''}#{'(type: ' + type.to_s + ', folder: ' + folder.to_s + ', item_name: ' + item_name.to_s + ', remove_duplicates: ' + remove_duplicates.to_s + ', rename: ' + rename.to_s + ', filter_criteria: ' + filter_criteria.to_s + ', no_prompt: ' + no_prompt.to_s + ', folder_hierarchy: ' + folder_hierarchy.to_s + ')' if Env.debug?}", 0)
    files, raw_filtered, cache_name = nil, [], folder.to_s + type.to_s + filter_criteria.length.to_s
    Utils.lock_block(__method__.to_s + cache_name) {
      file_criteria = {'regex' => '.*' + StringUtils.regexify(item_name.gsub(/(\w*)\(\d+\)/, '\1').strip.gsub(/ /, '.')) + '.*'}
      raw_filtered += FileUtils.search_folder(folder, filter_criteria.merge(file_criteria)) if filter_criteria && !filter_criteria.empty?
      if @media_list[cache_name].nil? || item_name.to_s != '' || remove_duplicates.to_i > 0 ||
          (filter_criteria && !filter_criteria.empty?) || (rename && !rename.empty?)
        FileUtils.search_folder(folder, file_criteria).each do |f|
          next unless f[0].match(Regexp.new(VALID_VIDEO_EXT))
          @media_list[cache_name, cache_expiration.to_i] = parse_media({:type => 'file', :name => f[0]}, type, no_prompt, @media_list[cache_name] || {}, folder_hierarchy, rename, {}, folder)
        end
        @media_list[cache_name, cache_expiration.to_i] = handle_duplicates(@media_list[cache_name] || {}, remove_duplicates, no_prompt)
      elsif Env.debug?
        $speaker.speak_up("Cache of media_list [#{cache_name}] exists, returning it directly", 0)
      end
    }
    if filter_criteria && !filter_criteria.empty? && !@media_list[cache_name].empty?
      files = @media_list[cache_name]
      files.keep_if { |_, f| !(f[:files] & raw_filtered.flatten).empty? }
    end
    return files || @media_list[cache_name]
  rescue => e
    $speaker.tell_error(e, "Library.process_folder")
    @media_list[cache_name, cache_expiration.to_i] = nil
    {}
  end

  def self.rename_media_file(original, destination, type, item_name, item, no_prompt = 0, hard_link = 0, replaced_outdated = 0, folder_hierarchy = {})
    metadata = MediaInfo.identify_metadata(original, type, item_name, item, no_prompt, folder_hierarchy)
    destination = Utils.parse_filename_template(destination, metadata)
    if destination.nil?
      $speaker.speak_up "Destination of rename file '#{original}' is empty, skipping..."
      return ''
    end
    destination += ".#{metadata['extension'].downcase}"
    if metadata['is_found']
      if $speaker.ask_if_needed("Move '#{original}' to '#{destination}'? (y/n)", no_prompt, 'y').to_s == 'y'
        _, destination = FileUtils.move_file(original, destination, hard_link, replaced_outdated)
      end
    else
      destination = ''
    end
    destination
  end

end
class Library

  @refusal = 0

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

  def self.convert_media(path:, input_format:, output_format:, no_warning: 0, rename_original: 1, move_destination: '', search_pattern: '', qualities: nil)
    name, results = '', []
    type = EXTENSIONS_TYPE.select {|k, v| v.include?(input_format)}.first[0]
    return $speaker.speak_up("Unknown input format") unless type != ''
    unless VALID_CONVERSION_INPUTS[type] && VALID_CONVERSION_INPUTS[type].include?(input_format)
      return $speaker.speak_up("Invalid input format, needs to be one of #{VALID_CONVERSION_INPUTS[type]}")
    end
    unless VALID_CONVERSION_OUTPUT[type] && VALID_CONVERSION_OUTPUT[type].include?(output_format)
      return $speaker.speak_up("Invalid output format, needs to be one of #{VALID_CONVERSION_OUTPUT[type]}")
    end
    return if no_warning.to_i == 0 && input_format == 'pdf' && $speaker.ask_if_needed("WARNING: The images extractor is incomplete, can result in corrupted or incomplete CBZ file. Do you want to continue? (y/n)") != 'y'
    return $speaker.speak_up("#{path.to_s} does not exist!") unless File.exist?(path)
    if FileTest.directory?(path)
      FileUtils.search_folder(path, {'regex' => ".*#{search_pattern.to_s + '.*' if search_pattern.to_s != ''}\.#{input_format}"}).each do |f|
        results += convert_media(path: f[0], input_format: input_format, output_format: output_format, no_warning: 1, rename_original: rename_original, move_destination: move_destination)
      end
    elsif search_pattern.to_s != ''
      $speaker.speak_up "Can not use search_pattern if path is not a directory"
    else
      input_format = FileUtils.get_extension(path)
      Dir.chdir(File.dirname(path)) do
        move_destination = Dir.pwd if move_destination.to_s == ''
        name = File.basename(path).gsub(/(.*)\.[\w\d]{1,4}/, '\1')
        dest_file = "#{move_destination}/#{name.gsub(/^_?/, '')}.#{output_format}"
        final_file = dest_file
        if File.exist?(File.basename(dest_file))
          if input_format == output_format
            dest_file = "#{move_destination}/#{name.gsub(/^_?/, '')}.proper.#{output_format}"
          else
            return results
          end
        end
        $speaker.speak_up("Will convert #{name} to #{output_format.to_s.upcase} format #{dest_file}")
        FileUtils.mkdir(name) unless File.exist?(name)
        skipping = case type
                   when :books
                     Book.convert_comics(path, name, input_format, output_format, dest_file, no_warning)
                   when :music
                     Music.convert_songs(path, dest_file, input_format, output_format, qualities)
                   end
        return results if skipping.to_i > 0
        FileUtils.mv(File.basename(path), "_#{File.basename(path)}_") if rename_original.to_i > 0
        FileUtils.mv(dest_file, final_file) if final_file != dest_file
        $speaker.speak_up("#{name} converted!")
        results << final_file
      end
    end
    results
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    name.to_s != '' && Dir.exist?(File.dirname(path) + '/' + name) && FileUtils.rm_r(File.dirname(path) + '/' + name)
    []
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
    loop do
      complete_list = TraktAgent.list(source_list, '')
      if complete_list.empty?
        sleep 3600
        $speaker.speak_up("Empty list #{source_list}", 0)
        next
      end
      abort = 0
      list = TraktAgent.parse_custom_list(complete_list)
      path_list = {}
      list_size = 0
      list.map {|n, _| n}.uniq.each do |type|
        s, path_list[type] = get_media_list_size(list: complete_list, folder: source_folders, type_filter: type)
        list_size += s
      end
      list.each do |type, _|
        source_folders[type] = $speaker.ask_if_needed("What is the source folder for #{type} media?") if source_folders[type].nil? || source_folders[type] == ''
        dest_type = "#{dest_folder}/#{type.titleize}/"
        _, total_space = FileUtils.get_disk_space(dest_folder)
        while total_space <= list_size
          $speaker.speak_up "There is not enough space available on #{File.basename(dest_folder)}. You need an additional #{((list_size - total_space).to_d / 1024 / 1024 / 1024).round(2)} GB to copy the list"
          if $speaker.ask_if_needed("Do you want to edit the list now (y/n)?", no_prompt, 'n') != 'y'
            abort = 1
            break
          end
          create_custom_list(name: source_list, description: '', origin: source_list)
          list_size, _ = get_media_list_size(list: complete_list, folder: source_folders)
        end
        $speaker.speak_up("Not enough disk space, aborting...") if abort > 0
        abort = 1 if abort == 0 && $speaker.ask_if_needed("WARNING: All your disk #{dest_folder} will be replaced by the media from your list #{source_list}! Are you sure you want to proceed? (y/n)", no_prompt, 'y') != 'y'
        if abort == 0
          $speaker.speak_up("Deleting extra media...", 0)
          FileUtils.search_folder(dest_type).sort_by {|x| -x[0].length}.each do |p|
            if File.exist?(p[0])
              FileUtils.rm_r(p[0]) unless FileUtils.is_in_path(path_list[type].map {|i| StringUtils.clean_search(i).gsub(source_folders[type], dest_type)}, p[0])
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
            next if Env.pretend?
            args = ['--update', '--delete', '--recursive', '--partial', '--verbose', "--bwlimit=#{bandwith_limit}"]
            args += ['--times'] unless File.exist?(final_path)
            Rsync.run("#{p}/", final_path, args) do |result|
              if result.success?
                result.changes.each do |change|
                  $speaker.speak_up "#{change.filename} (#{change.summary})"
                end
              else
                $speaker.speak_up result.error
              end
            end
          end
          $speaker.speak_up("Finished copying media from #{source_list}!", 0)
        end
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
    dest_list = existing_lists.select {|l| l['name'] == name}.first
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
    dest_list = existing_lists.select {|l| l['name'] == name}.first
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
       'ended', 'not_ended', 'watched', 'canceled'].each do |cr|
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
          if (t_criteria['add_only'].to_i == 0 || !TraktAgent.search_list(type[0...-1], item, to_delete[type])) && (t_criteria['include'].nil? || !t_criteria['include'].include?(title)) && $speaker.ask_if_needed("Do you want to add #{type} '#{title}' (disk size #{[(size.to_d / 1024 / 1024 / 1024).round(2), 0].max} GB) to the list (y/n)", review_cr['add_all'].to_i, 'y') != 'y'
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
              item['seasons'].select! {|s| choice.map! {|n| n.to_i}.include?(s['number'])}
            end
          end
          print '.'
        end
      end
      new_list[type].map! do |i|
        i[type[0...-1]]['seasons'] = i['seasons'].map {|s| s.select {|k, _| k != 'episodes'}} if i['seasons']
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
          fetcher = Librarian.burst_thread {fetch_media_box_core(local_folder, remote_user, remote_server, remote_folder, clean_remote_folder, bandwith_limit, ssh_opts, active_hours, exclude_folders_in_check)}
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
        $speaker.tell_error(e, Utils.arguments_dump(binding))
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
    dup_files = medium[:files].select {|x| x[:type].to_s == 'file'}.group_by {|a| a[:parts].join}.select {|_, v| v.count >= threshold}.map {|_, v| v}.flatten
    return [] if dup_files.count < threshold
    dups_files = dup_files.select {|x| x[:type].to_s == 'file' && File.exists?(x[:name])} #You never know...
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
    $speaker.speak_up("The total disk size of this list is #{(list_size / 1024 / 1024 / 1024).round(2)} GB")
    return list_size, list_paths
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    return 0, []
  end

  def self.get_search_list(source_type, category, source, no_prompt = 0)
    return {} unless source['existing_folder'] && source['existing_folder'][category]
    search_list, cache_name = {}, "#{source_type}#{category}#{source['existing_folder'][category]}#{source['list_name']}"
    Utils.lock_block(__method__.to_s + cache_name) do
      search_list = BusVariable.new('search_list', Vash)
      case source_type
      when 'filesystem'
        search_list[cache_name, CACHING_TTL] = process_folder(type: category, folder: source['existing_folder'][category], no_prompt: no_prompt, filter_criteria: source['filter_criteria'])
      when 'trakt'
        $speaker.speak_up('Parsing trakt list, can take a long time...', 0)
        TraktAgent.list(source['list_name']).each do |item|
          type = item['type'] rescue next
          f = item[type]
          type = Utils.regularise_media_type(type)
          next if Time.now.year < (f['year'] || Time.now.year + 3)
          search_list[cache_name, CACHING_TTL] = parse_media({:type => 'trakt', :name => "#{f['title']} (#{f['year']})".gsub('/', ' ')},
                                                             type,
                                                             no_prompt,
                                                             search_list[cache_name] || {},
                                                             {},
                                                             {},
                                                             {:trakt_obj => f, :trakt_list => source['list_name'], :trakt_type => type},
                                                             '',
                                                             f['ids']
          )
        end
      end
    end
    (search_list[cache_name] || {}).deep_dup
  end

  def self.handle_completed_download(torrent_path:, torrent_name:, completed_folder:, destination_folder:, handling: {}, remove_duplicates: 0, folder_hierarchy: FOLDER_HIERARCHY, force_process: 0, root_process: 1, ensure_qualities: '')
    full_p = torrent_path + '/' + torrent_name
    handled, process_folder_list = 0, []
    handled_files = (
    if handling['file_types'].is_a?(Array)
      handling['file_types'].map {|o| o.is_a?(Hash) ? o.map {|k, _| k.downcase} : o.downcase} + ['rar', 'zip']
    else
      ['rar', 'zip']
    end).flatten
    if FileTest.directory?(full_p)
      FileUtils.search_folder(full_p, {'regex' => Regexp.new('.*\.(' + handled_files.join('|') + '$)').to_s}).each do |f|
        handled += handle_completed_download(
            torrent_path: File.dirname(f[0]),
            torrent_name: File.basename(f[0]),
            completed_folder: completed_folder,
            destination_folder: destination_folder,
            handling: handling,
            remove_duplicates: remove_duplicates,
            folder_hierarchy: Hash[folder_hierarchy.map {|k, v| [k, v.to_i + 1]}],
            force_process: force_process,
            root_process: 0,
            ensure_qualities: ensure_qualities
        )[0]
      end
    else
      $speaker.speak_up "Handling downloaded file '#{full_p}'" if Env.debug?
      extension = FileUtils.get_extension(torrent_name)
      if ['rar', 'zip'].include?(extension)
        FileUtils.extract_archive(extension, full_p, torrent_path + '/extfls')
        ensure_qualities = MediaInfo.parse_qualities(File.basename(torrent_path)).join('.') if ensure_qualities.to_s == ''
        handled += handle_completed_download(
            torrent_path: torrent_path,
            torrent_name: 'extfls',
            completed_folder: completed_folder,
            destination_folder: destination_folder,
            handling: handling,
            remove_duplicates: remove_duplicates,
            folder_hierarchy: Hash[folder_hierarchy.map {|k, v| [k, v.to_i + 1]}],
            force_process: force_process,
            root_process: 0,
            ensure_qualities: ensure_qualities
        )[0]
        FileUtils.rm_r(torrent_path + '/extfls')
      elsif handling['file_types']
        if force_process.to_i == 0 && !handled_files.include?(extension)
          $speaker.speak_up "Unsupported extension '#{extension}'"
          return handled
        end
        type = full_p.gsub(Regexp.new("^#{completed_folder}\/?([a-zA-Z1-9 _-]*)\/.*"), '\1')
        args = handling['file_types'].select {|x| x.is_a?(Hash) && x[extension]}.first
        if File.basename(File.dirname(full_p)).downcase == 'sample' || File.basename(full_p).match(/([\. -])?sample([\. -])?/)
          $speaker.speak_up 'File is a sample, skipping...'
          return handled
        end
        if File.stat(full_p).nlink > 1
          $speaker.speak_up 'File is already hard linked, skipping...'
          return handled
        end
        type.downcase!
        $speaker.speak_up "File type '#{type}'" if Env.debug?
        ttype = handling[type] && handling[type]['media_type'] ? handling[type]['media_type'] : 'unknown'
        item_name, item = MediaInfo.identify_title(full_p, ttype, 1, (folder_hierarchy[ttype] || FOLDER_HIERARCHY[ttype]), completed_folder)
        if args && args[extension] && args[extension]['convert_to'].to_s != ''
          convert_media(
              path: full_p,
              input_format: extension,
              output_format: args[extension]['convert_to'],
              no_warning: 1,
              rename_original: 0,
              move_destination: File.dirname(full_p)
          ).each do |nf|
            handled += handle_completed_download(
                torrent_path: File.dirname(nf),
                torrent_name: File.basename(nf),
                completed_folder: completed_folder,
                destination_folder: destination_folder,
                handling: handling,
                remove_duplicates: remove_duplicates,
                folder_hierarchy: folder_hierarchy,
                force_process: force_process,
                root_process: 0,
                ensure_qualities: ensure_qualities
            )[0]
          end
        elsif handling[type] && handling[type]['move_to']
          destination = rename_media_file(full_p, handling[type]['move_to'], ttype, item_name, item, 1, 1, 1, folder_hierarchy, ensure_qualities)
        else
          destination = full_p.gsub(completed_folder, destination_folder)
          FileUtils.move_file(full_p, destination, 1)
        end
        if defined?(destination) && destination != ''
          process_folder_list << [ttype, destination]
          handled = 1
        end
      elsif Env.debug?
        $speaker.speak_up 'File type not handled, skipping...'
      end
    end
    if root_process.to_i > 0
      $speaker.speak_up('Could not find any file to handle!') if handled == 0
      process_folder_list.each do |p|
        process_folder(type: p[0], folder: p[1], remove_duplicates: 1, no_prompt: 1, cache_expiration: 1)
      end
    end
    return handled, process_folder_list
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
            files[id][:files].select! {|x| x[:name].to_s != d[:name]}
          end
        end
      end
    end
    files
  end

  def self.list_missing_media(type, files, no_prompt = 0, delta = 10, include_specials = 0, qualities = {})
    cache_name, missing_media = type.to_s + delta.to_s + include_specials.to_s + files.count.to_s + qualities.length.to_s, Vash.new
    Utils.lock_block(__method__.to_s + cache_name) {
      missing_media = BusVariable.new('mising_media', Vash)
      if missing_media[cache_name].nil?
        missing_media[cache_name] = {}
        return missing_media[cache_name] if files[:shows].nil? & type == 'shows'
        qualifying_files = files.deep_dup
        qualifying_files.select! do |k, f|
          next if k.is_a?(Symbol)
          MediaInfo.qualities_file_filter(f, qualities)
        end
        missing_media[cache_name, CACHING_TTL] = case type
                                                 when 'shows'
                                                   TvSeries.list_missing_episodes(files, qualifying_files, no_prompt, delta, include_specials, qualities)
                                                 when 'movies'
                                                   MoviesSet.list_missing_movie(files, qualifying_files, no_prompt, delta)
                                                 end
      end
    }
    missing_media[cache_name]
  end

  def self.parse_media(file, type, no_prompt = 0, files = {}, folder_hierarchy = {}, rename = {}, file_attrs = {}, base_folder = '', ids = {}, item = nil, item_name = '')
    item_name, item = MediaInfo.identify_title(file[:formalized_name] || file[:name], type, no_prompt, (folder_hierarchy[type] || FOLDER_HIERARCHY[type]), base_folder, ids) unless item && item_name.to_s != ''
    unless (no_prompt.to_i == 0 && item_name.to_s != '') || item
      if Env.debug?
        $speaker.speak_up("File '#{File.basename(file[:name])}' not identified, skipping. (folder_hierarchy='#{folder_hierarchy}', base_folder='#{base_folder}', ids='#{ids}')")
      end
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
    return files if file[:type].to_s == 'file' && !File.exists?(file[:name])
    $speaker.speak_up("Adding #{file[:type]} '#{full_name}' (filename '#{File.basename(file[:name])}', ids '#{identifiers}') to list", 0) if Env.debug?
    if file[:type].to_s == 'file'
      Cache.queue_state_get('file_handling').each do |i, fs|
        if i.to_s != '' && identifiers.join.include?(i) && !fs.empty? && !fs.map {|obj| obj[:name] if obj[:type] == 'file'}.compact.include?(file[:name])
          ok = false
          fs.each do |f|
            $speaker.speak_up "Found a '#{f[:type]}'#{' (' + f[:name].to_s + ')' if [:type] == 'file'} to remove for file '#{File.basename(file[:name])}' (identifier '#{i}'), removing now..." #if Env.debug?
            ok = TraktAgent.remove_from_list([f[:trakt_obj]], f[:trakt_list], f[:trakt_type]) if f[:type] == 'trakt'
            if f[:type] == 'file'
              ok = if File.exist?(f[:name])
                     FileUtils.rm(f[:name])
                   else
                     true
                   end
            end
          end
          Cache.queue_state_remove('file_handling', i) if ok
        end
      end
    end
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
        next if source['existing_folder'].nil? || source['existing_folder'][ct].nil? || ct != category
        unless existing_files[ct]
          existing_files[ct] = process_folder(type: ct, folder: source['existing_folder'][ct], no_prompt: no_prompt, remove_duplicates: 0)
          existing_files[ct][:shows] = search_list[:shows] if search_list[:shows]
        end
        case ct
        when 'movies'
          search_list[id][:files] = [] unless search_list[id][:files].is_a?(Array)
          if (source['upgrade'].to_i > 0 && MediaInfo.qualities_file_filter(existing_files[ct][id], qualities)) ||
              source['get_missing_set'].to_i > 0
            search_list.delete(id)
          else
            already_exists = get_duplicates(existing_files[ct][id], 1)
            already_exists.each do |ae|
              if $speaker.ask_if_needed("Replace already existing file #{ae[:name]}? (y/n)", [no_prompt.to_i, source['upgrade'].to_i].max, source_type == 'trakt' ? 'n' : 'y').to_s == 'y'
                search_list[id][:files] << ae
              elsif $speaker.ask_if_needed("Remove #{search_list[id][:name]} from the search list? (y/n)", no_prompt.to_i, 'y').to_s == 'y'
                TraktAgent.remove_from_list([search_list[id][:trakt_obj]], source['list_name'], ct) if search_list[id][:trakt_obj]
                search_list.delete(id)
              end
            end
          end
        when 'shows'
          search_list.delete(id)
        end
        missing[ct] = list_missing_media(
            ct,
            existing_files[ct],
            no_prompt,
            (source['delta'] || 10),
            source['include_specials'],
            source['upgrade'].to_i > 0 ? qualities : {}
        ) unless missing[ct] || (ct == 'movies' && source['get_missing_set'].to_i == 0)
      end
      ['movies', 'shows'].each {|t| search_list.merge!(missing[t]) if missing[t]}
      search_list.keep_if {|_, f| !f.is_a?(Hash) || f[:type] != 'movies' || (!f[:release_date].nil? && f[:release_date] < Time.now)}
    end
    return search_list, existing_files
  end

  def self.process_folder(type:, folder:, item_name: '', remove_duplicates: 0, rename: {}, filter_criteria: {}, no_prompt: 0, folder_hierarchy: {}, cache_expiration: CACHING_TTL)
    $speaker.speak_up("Processing folder #{folder}...#{' for ' + item_name.to_s if item_name.to_s != ''}#{'(type: ' + type.to_s + ', folder: ' + folder.to_s + ', item_name: ' + item_name.to_s + ', remove_duplicates: ' + remove_duplicates.to_s + ', rename: ' + rename.to_s + ', filter_criteria: ' + filter_criteria.to_s + ', no_prompt: ' + no_prompt.to_s + ', folder_hierarchy: ' + folder_hierarchy.to_s + ')' if Env.debug?}", 0)
    files, raw_filtered, cache_name, media_list = nil, [], folder.to_s + type.to_s + item_name.to_s, {}
    Utils.lock_block(__method__.to_s + cache_name) {
      file_criteria = {'regex' => '.*' + StringUtils.regexify(item_name.gsub(/(\w*)\(\d+\)/, '\1').strip.gsub(/ /, '.')) + '.*'}
      raw_filtered += FileUtils.search_folder(folder, filter_criteria.merge(file_criteria)) if filter_criteria && !filter_criteria.empty?
      media_list = BusVariable.new('media_list', Vash)
      if media_list[cache_name].nil? || remove_duplicates.to_i > 0 || (rename && !rename.empty?)
        FileUtils.search_folder(folder, file_criteria).each do |f|
          next unless f[0].match(Regexp.new(VALID_VIDEO_EXT))
          Librarian.route_cmd(
              ['Library', 'parse_media', {:type => 'file', :name => f[0]}, type, no_prompt, {}, folder_hierarchy, rename, {}, folder],
              1,
              Thread.current[:object],
              8
          )
        end
        media_list[cache_name, cache_expiration.to_i] = Daemon.consolidate_children
        media_list[cache_name, cache_expiration.to_i] = handle_duplicates(media_list[cache_name] || {}, remove_duplicates, no_prompt)
      elsif Env.debug?
        $speaker.speak_up("Cache of media_list [#{cache_name}] exists, returning it directly", 0)
      end
    }
    if filter_criteria && !filter_criteria.empty? && !media_list[cache_name].empty?
      files = media_list[cache_name].dup
      files.keep_if {|k, f| !k.is_a?(Symbol) && !(f[:files].map {|x| x[:name]} & raw_filtered.flatten).empty?}
    end
    return files || media_list[cache_name]
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    media_list.delete(cache_name)
    {}
  end

  def self.rename_media_file(original, destination, type, item_name, item, no_prompt = 0, hard_link = 0, replaced_outdated = 0, folder_hierarchy = {}, ensure_qualities = '')
    $speaker.speak_up Utils.arguments_dump(binding) if Env.debug?
    destination += "#{File.basename(original).gsub('.' + FileUtils.get_extension(original), '')}" if FileTest.directory?(destination)
    metadata = MediaInfo.identify_metadata(original, type, item_name, item, no_prompt, folder_hierarchy, '', ensure_qualities)
    destination = Utils.parse_filename_template(destination, metadata)
    if destination.to_s == ''
      $speaker.speak_up "Destination of rename file '#{original}' is empty, skipping..."
      return ''
    end
    destination += ".#{metadata['extension'].downcase}"
    if metadata['is_found']
      _, destination = FileUtils.move_file(original, destination, hard_link, replaced_outdated, no_prompt)
    else
      $speaker.speak_up "File '#{original}' not identified, skipping..."
      destination = ''
    end
    destination
  end

end
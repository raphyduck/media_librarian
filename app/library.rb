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
    Speaker.speak_up("Starting cleaning remote files on #{remote_user}@#{remote_server}:#{path} using criteria #{filter_criteria}, no_prompt=#{no_prompt}")
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

  def self.compress_archive(folder, name)
    Zip::Archive.open(name, Zip::CREATE) do |ar|
      ar.add_dir(folder)
      #Dir.glob("#{folder}/**/*").each do |path|
      Utils.search_folder(folder, {'includedir' => 1}).each do |path|
        if File.directory?(path[0])
          ar.add_dir(path[0])
        else
          ar.add_file(path[0], path[0]) # add_file(<entry name>, <source path>)
        end
      end
    end
  end

  def self.convert_pdf_cbz(path:)
    return if Speaker.ask_if_needed("WARNING: The images extractor is incomplete, can result in corrupted or incomplete CBZ file. Do you want to continue? (y/n)") != 'y'
    return Speaker.speak_up("#{path.to_s} does not exist!") unless File.exist?(path)
    if FileTest.directory?(path)
      Utils.search_folder(path, {'regex' => '.*\.pdf'}).each do |f|
        convert_pdf_cbz(path: f[0])
      end
    else
      Dir.chdir(File.dirname(path)) do
        name = File.basename(path).gsub(/(.*)\.[\w]{1,4}/, '\1')
        dest_file = "#{name.gsub(/^_?/, '')}.cbz"
        return if File.exist?(dest_file)
        Speaker.speak_up("Will convert #{name} to CBZ format #{dest_file}")
        Dir.mkdir(name)
        extractor = ExtractImages::Extractor.new
        Dir.chdir(name) do
          PDF::Reader.open('../' +File.basename(path)) do |reader|
            reader.pages.each do |page|
              extractor.page(page)
            end
          end
        end
        compress_archive(name, dest_file)
        FileUtils.rm_r(name)
        FileUtils.mv(File.basename(path), "_#{File.basename(path)}_")
      end
    end
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
      Utils.search_folder(dest_type, {'includedir' => 1}).sort_by { |x| -x[0].length }.each do |p|
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
    Speaker.speak_up("Finished copying media from #{source_list}!")
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
        if (t_criteria[cr] && t_criteria[cr].to_i == 0) || Speaker.ask_if_needed("Do you want to add #{type} #{cr.gsub('_', ' ')}? (y/n)", t_criteria[cr].nil? ? 0 : 1, 'y') != 'y'
          new_list[type] = TraktList.filter_trakt_list(new_list[type], type, cr, t_criteria['include'], t_criteria['add_only'], to_delete[type])
        end
      end
      if type =='movies'
        ['released_before', 'released_after', 'days_older', 'days_newer'].each do |cr|
          if t_criteria[cr].to_i != 0 || Speaker.ask_if_needed("Enter the value to keep only #{type} #{cr.gsub('_', ' ')}: (empty to not use this filter)", t_criteria[cr].nil? ? 0 : 1, t_criteria[cr]) != ''
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

  def self.create_playlists(folder:, criteria: {}, move_untagged: '', remove_existing_playlists: 1, random: 0)
    criteria = eval(criteria) if criteria.is_a?(String)
    folder = "#{folder}/" unless folder[-1] == '/'
    ordered_collection = {}
    cpt = 0
    crs = ['artist', 'albumartist', 'album', 'year', 'decade', 'genre']
    library = {}
    Speaker.speak_up("Listing all songs in #{folder}")
    files = Utils.search_folder(folder, {'regex' => '.*\.[mM][pP]3'})
    files.each do |p_song|
      cpt += 1
      song = Mp3Info.open(p_song[0])
      f_song = {
          :path => p_song[0].gsub(folder,''),
          :length => song.length,
          :artist => (song.tag.artist || song.tag2.TPE1).to_s.strip.gsub(/\u0000/,''),
          :albumartist => (song.tag2.TPE2 || song.tag.artist || song.tag2.TPE1).to_s.strip.gsub(/\u0000/,''),
          :title => (song.tag.title || song.tag2.TIT2).to_s.strip.gsub(/\u0000/,''),
          :album => (song.tag.album || song.tag2.TALB).to_s.strip.gsub(/\u0000/,''),
          :year => (song.tag.year || song.tag2.TYER || 0).to_s.strip.gsub(/\u0000/,''),
          :track_nr => (song.tag.track_nr || song.tag2.TRCK).to_s.strip.gsub(/\u0000/,''),
          :genre => (song.tag.genre_s || song.tag2.TCON).to_s.strip.gsub(/\(\d*\)/,'').gsub(/\u0000/,'')
      }
      f_song[:decade] = "#{f_song[:year][0...-1]}0"
      f_song[:decade] = nil if f_song[:decade].to_i == 0
      if f_song[:genre].to_s == '' || f_song[:artist].to_s == '' || f_song[:album].to_s == ''
        if Speaker.ask_if_needed("File #{f_song[:path]} has no proper tags, missing: #{'genre,' if f_song[:genre].to_s == ''}#{'artist,' if f_song[:artist].to_s == ''}#{'album,' if f_song[:album].to_s == ''} do you want to move it to another folder? (y/n)", move_untagged.to_s != '' ? 1 : 0, 'y') == 'y'
          destination_folder = Speaker.ask_if_needed("Enter the full path of the folder to move the files into: ", move_untagged.to_s != '' ? 1 : 0, move_untagged.to_s)
          FileUtils.mkdir_p("#{destination_folder}/#{File.basename(File.dirname(f_song[:path]))}")
          FileUtils.mv("#{p_song[0]}", "#{destination_folder}/#{File.basename(File.dirname(f_song[:path]))}/")
        end
        next
      end
      sorter_name = f_song[:genre].to_s+f_song[:albumartist].to_s+f_song[:year].to_s+f_song[:album].to_s
      ordered_collection[sorter_name] = [] if ordered_collection[sorter_name].nil?
      ordered_collection[sorter_name] << f_song
      crs.each do |cr|
        library[cr] = [] unless library[cr]
        library[cr] << f_song[cr.to_sym] unless f_song[cr.to_sym].nil? || library[cr].include?(f_song[cr.to_sym])
      end
      print "Processed song #{cpt} / #{files.count}\r"
    end
    Speaker.speak_up("Finished processing songs, now generating playlists...")
    collection = ordered_collection.sort_by{|k,_| k}.map{|x| x[1].sort_by {|s| s[:track_nr].to_i}}
    collection.shuffle! if random.to_i > 0
    collection.flatten!
    if remove_existing_playlists.to_i > 0
      Utils.search_folder(folder, {'regex' => '.*\.m3u', 'maxdepth' => 1}).each do |path|
        FileUtils.rm(path[0])
      end
    end
    crs.each do |cr|
      if Speaker.ask_if_needed("Do you want to generate playlists based on #{cr}? (y/n)", criteria[cr].to_s != '' ? 1 : 0, criteria[cr].to_i > 0 ? 'y' : 'n') == 'y'
        if library[cr].nil? || library[cr].empty?
          Speaker.speak_up "No collection of #{cr} found!"
          next
        end
        Speaker.speak_up("Will generate playlists based on #{cr}")
        library[cr].each do |p|
          generate_playlist("#{folder}/#{cr}s-#{p.gsub('/','').gsub(/[^\u0000-\u007F]+/,'_').gsub(' ','_')}".gsub(/\/*$/,''), collection.select{|s| s[cr.to_sym] == p})
        end
        Speaker.speak_up("#{library[cr].length} #{cr} playlists have been generated")
      end
    end
  end

  def self.duplicate_search(folder, title, original, no_prompt = 0, type = 'movies')
    Speaker.speak_up("Looking for duplicates of #{title}...")
    dups = Utils.search_folder(folder, {'regex' => '.*' + title.gsub(/(\w*)\(\d+\)/, '\1').strip.gsub(/ /, '.') + '.*', 'exclude_strict' => original})
    corrected_dups = []
    if dups.count > 0
      dups.each do |d|
        case type
          when 'movies'
            d_title, _ = MediaInfo.movie_title_lookup(File.basename(File.dirname(d)))
          else
            next
        end
        corrected_dups << d if d_title == title
      end
    end
    if corrected_dups.length > 0 && Speaker.ask_if_needed("Duplicate(s) found for film #{title}. Original is #{original}. Duplicates are:#{NEW_LINE}" + corrected_dups.map { |d| "#{d[0]}#{NEW_LINE}" }.to_s + ' Do you want to remove them? (y/n)', no_prompt) == 'y'
      corrected_dups.each do |d|
        FileUtils.rm_r(d[0])
      end
    else
      Speaker.speak_up('No duplicates found')
    end
  end

  def self.fetch_media_box(local_folder:, remote_user:, remote_server:, remote_folder:, reverse_folder: [], move_if_finished: [], clean_remote_folder: [], bandwith_limit: 0, active_hours: [], ssh_opts: {}, exclude_folders_in_check: [], monitor_options: {})
    loop do
      if Utils.check_if_inactive(active_hours)
        sleep 30
        next
      end
      exit_status = nil
      low_b = 0
      while exit_status.nil? && !Utils.check_if_inactive(active_hours)
        fetcher = Thread.new { fetch_media_box_core(local_folder, remote_user, remote_server, remote_folder, move_if_finished, clean_remote_folder, bandwith_limit, ssh_opts, active_hours, reverse_folder, exclude_folders_in_check) }
        while fetcher.alive?
          if Utils.check_if_inactive(active_hours) || low_b > 12
            Speaker.speak_up('Bandwidth too low, restarting the synchronisation')
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
      end
      $email_msg = ''
      sleep 3600 unless exit_status.nil?
    end
  end

  def self.fetch_media_box_core(local_folder, remote_user, remote_server, remote_folder, move_if_finished = [], clean_remote_folder = [], bandwith_limit = 0, ssh_opts = {}, active_hours = [], reverse_folder = [], exclude_folders = [])
    $email_msg = ''
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
    if !Utils.check_if_inactive(active_hours) && reverse_folder && reverse_folder.is_a?(Array)
      reverse_folder.each do |f|
        reverse_box = "#{remote_user}@#{remote_server}:#{f}"
        Speaker.speak_up("Starting reverse folder synchronisation with #{reverse_box} - #{Time.now.utc}")
        Rsync.run("#{reverse_folder}/", "#{reverse_box}", ['--verbose', '--progress', '--recursive', '--acls', '--times', '--remove-source-files', '--human-readable', "--bwlimit=#{bandwith_limit}"]) do |result|
          if result.success?
            result.changes.each do |change|
              Speaker.speak_up "#{change.filename} (#{change.summary})"
            end
          else
            Speaker.speak_up result.error
          end
        end
        Speaker.speak_up("Finished reverse folder synchronisation with #{reverse_box} - #{Time.now.utc}")
      end
    end
    compare_remote_files(path: local_folder, remote_server: remote_server, remote_user: remote_user, filter_criteria: {'days_newer' => 10, 'exclude_path' => exclude_folders}, ssh_opts: ssh_opts, no_prompt: 1) unless rsynced_clean || !Utils.check_if_inactive(active_hours)
    Speaker.speak_up("Finished media box synchronisation - #{Time.now.utc}")
    Report.deliver(object_s: 'fetch_media_box - ' + Time.now.strftime("%a %d %b %Y").to_s) if $email && $action
    raise "Rsync failure" unless rsynced_clean
  end

  def self.generate_playlist(name, list)
    Speaker.speak_up("Generating playlist #{name}.m3u with #{list.count} elements")
    File.open("#{name}.m3u", "w:UTF-8") do |playlist|
      playlist.puts "#EXTM3U"
      list.each do |s|
        playlist.puts "\#EXTINF:#{s[:length].round},#{s[:artist]} - #{s[:title]}"
        playlist.puts "#{s[:path]}"
      end
    end
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
    movies = []
    Speaker.speak_up('Parsing movie list, can take a long time...')
    self.parse_watch_list(source).each do |item|
      movie = item['movie']
      next if movie.nil? || movie['year'].nil? || Time.now.year < movie['year']
      imdb_movie = MediaInfo.moviedb_search(movie['title'], true)
      movie['release_date'] = imdb_movie.release_date.gsub(/\(\w+\)/,'').to_date rescue movie['release_date'] = Date.new(movie['year'])
      next if movie['release_date'] >= Date.today
      movies << movie
      print '...'
    end
    movies.sort_by! { |m| m['release_date']}
    movies.each do |movie|
      break if break_processing(no_prompt)
      if Speaker.ask_if_needed("Do you want to look for releases of movie #{movie['title'].to_s + ' (' + movie['year'].to_s + ')'} (released on #{movie['release_date']})? (y/n)", no_prompt, 'y') != 'y'
        @refusal += 1
        next
      else
        @refusal == 0
      end
      self.duplicate_search(dest_folder, movie['title'], nil, no_prompt, type)
      found = TorrentSearch.search(keywords: (movie['title'].to_s + ' ' + movie['year'].to_s + ' ' + extra_keywords).gsub(/[:,-\/\[\]]/,''), limit: 10, category: 'movies', no_prompt: no_prompt, filter_dead: 1, move_completed: dest_folder, rename_main: movie['title'].to_s + ' (' + movie['year'].to_s + ')', main_only: 1)
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
        title, found = MediaInfo.movie_title_lookup(title)
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
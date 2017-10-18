class Library

  @refusal = 0
  @processed = []

  def self.already_processed?(item)
    already_processed = @processed.include?(item)
    @processed << item
    return already_processed
  end

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
    ssh_opts = eval(ssh_opts) if ssh_opts.is_a?(String)
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
  rescue => e
    $speaker.tell_error(e, "Library.compare_remote_files")
  end

  def self.compress_comics(path:, destination: '', output_format: 'cbz', remove_original: 1, skip_compress: 0)
    destination = path.gsub(/\/$/, '') + '.' + output_format if destination.to_s == ''
    case output_format
      when 'cbz'
        Utils.compress_archive(path, destination) if skip_compress.to_i == 0
      else
        $speaker.speak_up('Nothing to do, skipping')
        skip_compress = 1
    end
    FileUtils.rm_r(path) if remove_original.to_i > 0
    $speaker.speak_up("Folder #{File.basename(path)} compressed to #{output_format} comic")
    return skip_compress
  rescue => e
    $speaker.tell_error(e, "Library.compress_comics")
  end

  def self.convert_comics(path:, input_format:, output_format:, no_warning: 0, rename_original: 1, move_destination: '')
    name = ''
    valid_inputs = ['cbz', 'pdf', 'cbr']
    valid_outputs = ['cbz']
    return $speaker.speak_up("Invalid input format, needs to be one of #{valid_inputs}") unless valid_inputs.include?(input_format)
    return $speaker.speak_up("Invalid output format, needs to be one of #{valid_outputs}") unless valid_outputs.include?(output_format)
    return if no_warning.to_i == 0 && input_format == 'pdf' && $speaker.ask_if_needed("WARNING: The images extractor is incomplete, can result in corrupted or incomplete CBZ file. Do you want to continue? (y/n)") != 'y'
    return $speaker.speak_up("#{path.to_s} does not exist!") unless File.exist?(path)
    if FileTest.directory?(path)
      Utils.search_folder(path, {'regex' => ".*\.#{input_format}"}).each do |f|
        convert_comics(path: f[0], input_format: input_format, output_format: output_format, no_warning: 1, rename_original: rename_original, move_destination: move_destination)
      end
    else
      skipping = 0
      Dir.chdir(File.dirname(path)) do
        name = File.basename(path).gsub(/(.*)\.[\w]{1,4}/, '\1')
        dest_file = "#{move_destination}/#{name.gsub(/^_?/, '')}.#{output_format}"
        return if File.exist?(dest_file)
        $speaker.speak_up("Will convert #{name} to #{output_format.to_s.upcase} format #{dest_file}")
        Dir.mkdir(name) unless File.exist?(name)
        Dir.chdir(name) do
          case input_format
            when 'pdf'
              extractor = ExtractImages::Extractor.new
              extracted = 0
              PDF::Reader.open('../' +File.basename(path)) do |reader|
                reader.pages.each do |page|
                  extracted = extractor.page(page)
                end
              end
              unless extracted > 0
                $speaker.ask_if_needed("WARNING: Error extracting images, skipping #{name}! Press any key to continue!", no_warning)
                skipping = 1
              end
            when 'cbr', 'cbz'
              Utils.extract_archive(input_format, '../' +File.basename(path), '.')
            else
              $speaker.speak_up('Nothing to do, skipping')
              skipping = 1
          end
        end
        skipping = compress_comics(path: name, destination: dest_file, output_format: output_format, remove_original: 1, skip_compress: skipping)
        return if skipping > 0
        FileUtils.mv(File.basename(path), "_#{File.basename(path)}_") if rename_original.to_i > 0
        $speaker.speak_up("#{name} converted!")
      end
    end
  rescue => e
    $speaker.tell_error(e, "Library.convert_comics")
    name.to_s != '' && Dir.exist?(File.dirname(path) + '/' + name) && FileUtils.rm_r(File.dirname(path) + '/' + name)
  end

  def self.copy_media_from_list(source_list:, dest_folder:, source_folders: {}, bandwith_limit: 0, no_prompt: 0)
    source_folders = eval(source_folders) if source_folders.is_a?(String)
    source_folders = {} if source_folders.nil?
    return $speaker.speak_up("Invalid destination folder") if dest_folder.nil? || dest_folder == '' || !File.exist?(dest_folder)
    complete_list = TraktList.list(source_list, '')
    return $speaker.speak_up("Empty list #{source_list}") if complete_list.empty?
    abort = 0
    list = TraktList.parse_custom_list(complete_list)
    list.each do |type, _|
      source_folders[type] = $speaker.ask_if_needed("What is the source folder for #{type} media?") if source_folders[type].nil? || source_folders[type] == ''
      dest_type = "#{dest_folder}/#{type.titleize}/"
      list_size, _ = get_media_list_size(list: complete_list, folder: source_folders)
      _, total_space = Utils.get_disk_space(dest_folder)
      while total_space <= list_size
        size_error = "There is not enough space available on #{File.basename(dest_folder)}. You need an additional #{((list_size-total_space).to_d/1024/1024/1024).round(2)} GB to copy the list"
        if $speaker.ask_if_needed("#{size_error}. Do you want to edit the list now (y/n)?", no_prompt, 'n') != 'y'
          Report.deliver(object_s: 'copy_media_from_list - Not enough space on disk to copy list ' + source_list.to_s + ' - ' + type.to_s, body_s: size_error)
          abort = 1
          break
        end
        create_custom_list(source_list, '', source_list)
        list_size, _ = get_media_list_size(list: complete_list, folder: source_folders)
      end
      return $speaker.speak_up("Not enough disk space, aborting...") if abort > 0
      return if $speaker.ask_if_needed("WARNING: All your disk #{dest_folder} will be replaced by the media from your list #{source_list}! Are you sure you want to proceed? (y/n)", no_prompt, 'y') != 'y'
      _, paths = get_media_list_size(list: complete_list, folder: source_folders, type_filter: type)
      $speaker.speak_up 'Deleting extra media...'
      Utils.search_folder(dest_type, {'includedir' => 1}).sort_by { |x| -x[0].length }.each do |p|
        FileUtils.rm_r(p[0]) unless Utils.is_in_path(paths.map { |i| i.gsub(source_folders[type], dest_type) }, p[0])
      end
      Dir.mkdir(dest_type) unless File.exist?(dest_type)
      $speaker.speak_up('Syncing new media...')
      sync_error = ''
      paths.each do |p|
        final_path = p.gsub("#{source_folders[type]}/", dest_type)
        FileUtils.mkdir_p(File.dirname(final_path)) unless File.exist?(File.dirname(final_path))
        Rsync.run("'#{p}'/", "'#{final_path}'", ['--update', '--times', '--delete', '--recursive', '--verbose', "--bwlimit=#{bandwith_limit}"]) do |result|
          if result.success?
            result.changes.each do |change|
              $speaker.speak_up "#{change.filename} (#{change.summary})"
            end
          else
            sync_error += result.error.to_s
            $speaker.speak_up result.error
          end
        end
      end
      Report.deliver(object_s: 'copy_media_from_list - Errors syncing list ' + source_list.to_s + ' to disk ' + type.to_s, body_s: sync_error) if sync_error != ''
    end
    $speaker.speak_up("Finished copying media from #{source_list}!")
  end

  def self.copy_trakt_list(name:, description:, origin: 'collection', criteria: {})
    $speaker.speak_up("Fetching items from #{origin}...")
    criteria = eval(criteria) if criteria.is_a?(String)
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
    criteria = eval(criteria) if criteria.is_a?(String)
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
      TraktList.remove_from_list(to_delete[type], name, type) unless to_delete.nil? || to_delete.empty? || to_delete[type].nil? || to_delete[type].empty?
      TraktList.add_to_list(new_list[type], 'custom', name, type)
    end
    $speaker.speak_up("List #{name} is up to date!")
  rescue => e
    $speaker.tell_error(e, "Library.create_custom_list")
  end

  def self.create_playlists(folder:, criteria: {}, move_untagged: '', remove_existing_playlists: 1, random: 0)
    criteria = eval(criteria) if criteria.is_a?(String)
    folder = "#{folder}/" unless folder[-1] == '/'
    ordered_collection = {}
    cpt = 0
    crs = ['artist', 'albumartist', 'album', 'year', 'decade', 'genre']
    library = {}
    $speaker.speak_up("Listing all songs in #{folder}")
    files = Utils.search_folder(folder, {'regex' => '.*\.[mM][pP]3'})
    files.each do |p_song|
      cpt += 1
      song = Mp3Info.open(p_song[0])
      f_song = {
          :path => p_song[0].gsub(folder, ''),
          :length => song.length,
          :artist => (song.tag.artist || song.tag2.TPE1).to_s.strip.gsub(/\u0000/, ''),
          :albumartist => (song.tag2.TPE2 || song.tag.artist || song.tag2.TPE1).to_s.strip.gsub(/\u0000/, ''),
          :title => (song.tag.title || song.tag2.TIT2).to_s.strip.gsub(/\u0000/, ''),
          :album => (song.tag.album || song.tag2.TALB).to_s.strip.gsub(/\u0000/, ''),
          :year => (song.tag.year || song.tag2.TYER || 0).to_s.strip.gsub(/\u0000/, ''),
          :track_nr => (song.tag.track_nr || song.tag2.TRCK).to_s.strip.gsub(/\u0000/, ''),
          :genre => (song.tag.genre_s || song.tag2.TCON).to_s.strip.gsub(/\(\d*\)/, '').gsub(/\u0000/, '')
      }
      f_song[:decade] = "#{f_song[:year][0...-1]}0"
      f_song[:decade] = nil if f_song[:decade].to_i == 0
      if f_song[:genre].to_s == '' || f_song[:artist].to_s == '' || f_song[:album].to_s == ''
        if $speaker.ask_if_needed("File #{f_song[:path]} has no proper tags, missing: #{'genre,' if f_song[:genre].to_s == ''}#{'artist,' if f_song[:artist].to_s == ''}#{'album,' if f_song[:album].to_s == ''} do you want to move it to another folder? (y/n)", move_untagged.to_s != '' ? 1 : 0, 'y') == 'y'
          destination_folder = $speaker.ask_if_needed("Enter the full path of the folder to move the files into: ", move_untagged.to_s != '' ? 1 : 0, move_untagged.to_s)
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
    $speaker.speak_up("Finished processing songs, now generating playlists...")
    collection = ordered_collection.sort_by { |k, _| k }.map { |x| x[1].sort_by { |s| s[:track_nr].to_i } }
    collection.shuffle! if random.to_i > 0
    collection.flatten!
    Dir.mkdir(folder) unless FileTest.directory?(folder)
    if remove_existing_playlists.to_i > 0
      Utils.search_folder(folder, {'regex' => '.*\.m3u'}).each do |path|
        FileUtils.rm(path[0])
      end
    end
    crs.each do |cr|
      if $speaker.ask_if_needed("Do you want to generate playlists based on #{cr}? (y/n)", criteria[cr].to_s != '' ? 1 : 0, criteria[cr].to_i > 0 ? 'y' : 'n') == 'y'
        if library[cr].nil? || library[cr].empty?
          $speaker.speak_up "No collection of #{cr} found!"
          next
        end
        $speaker.speak_up("Will generate playlists based on #{cr}")
        library[cr].each do |p|
          generate_playlist("#{folder}/#{cr}s-#{p.gsub('/', '').gsub(/[^\u0000-\u007F]+/, '_').gsub(' ', '_')}".gsub(/\/*$/, ''), collection.select { |s| s[cr.to_sym] == p })
        end
        $speaker.speak_up("#{library[cr].length} #{cr} playlists have been generated")
      end
    end
  end

  def self.duplicate_search(folder, title, original, no_prompt = 0, type = 'movies')
    $speaker.speak_up("Looking for duplicates of #{title}...")
    replaced = nil
    dups = Utils.search_folder(folder, {'regex' => '.*' + Utils.regexify(title.gsub(/(\w*)\(\d+\)/, '\1').strip.gsub(/ /, '.')) + '.*', 'exclude_strict' => original[1]})
    corrected_dups = []
    processed = []
    if dups.count > 0
      dups.each do |d|
        case type
          when 'movies'
            next if processed.include?(d[1])
            titles, _ = MediaInfo.movie_title_lookup(d[1])
            d_title, _ = titles[0]
            processed << d[1]
          else
            next
        end
        corrected_dups << d if d_title == title
      end
    end
    if corrected_dups.length > 0 && $speaker.ask_if_needed("Duplicate(s) found for film #{title}. Original is #{original}. Duplicates are:#{NEW_LINE}" + corrected_dups.map { |d| "#{d[0]}#{NEW_LINE}" }.to_s + ' Do you want to remove them? (y/n)', no_prompt) == 'y'
      corrected_dups.each do |d|
        FileUtils.rm_r(File.dirname(d[0]))
      end
    elsif corrected_dups.length > 0 && !original[1].nil? && $speaker.ask_if_needed("Would you prefer to delete the original #{original[1]}? (y/n)", no_prompt) == 'y'
      FileUtils.rm_r(File.dirname(original[0]))
      replaced = 0
    else
      $speaker.speak_up('No duplicates found')
    end
    return replaced
  end

  def self.fetch_media_box(local_folder:, remote_user:, remote_server:, remote_folder:, reverse_folder: [], move_if_finished: [], clean_remote_folder: [], bandwith_limit: 0, active_hours: [], ssh_opts: {}, exclude_folders_in_check: [], monitor_options: {}, rsync_shell: '')
    $email_msg = ''
    loop do
      if Utils.check_if_inactive(active_hours) && $email_msg != ''
        Report.deliver(object_s: 'fetch_media_box - ' + Time.now.strftime("%a %d %b %Y").to_s) if $email && $action
        $email_msg = ''
      end
      if Utils.check_if_inactive(active_hours)
        sleep 30
        next
      end
      exit_status = nil
      low_b = 0
      while exit_status.nil? && !Utils.check_if_inactive(active_hours)
        fetcher = Thread.new { fetch_media_box_core(local_folder, remote_user, remote_server, remote_folder, move_if_finished, clean_remote_folder, bandwith_limit, ssh_opts, active_hours, reverse_folder, exclude_folders_in_check) }
        while fetcher.alive?
          if Utils.check_if_inactive(active_hours) || low_b > 18
            $speaker.speak_up('Bandwidth too low, restarting the synchronisation') if low_b > 18
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
      sleep 3600 unless exit_status.nil?
    end
  end

  def self.fetch_media_box_core(local_folder, remote_user, remote_server, remote_folder, move_if_finished = [], clean_remote_folder = [], bandwith_limit = 0, ssh_opts = {}, active_hours = [], reverse_folder = [], exclude_folders = [])
    remote_box = "#{remote_user}@#{remote_server}:#{remote_folder}"
    rsynced_clean = false
    $speaker.speak_up("Starting media synchronisation with #{remote_box} - #{Time.now.utc}")
    base_opts = ['--verbose', '--recursive', '--acls', '--times', '--remove-source-files', '--human-readable', "--bwlimit=#{bandwith_limit}"]
    opts = base_opts + ["--partial-dir=#{local_folder}/.rsync-partial"]
    $speaker.speak_up("Running the command: rsync #{opts.join(' ')} #{remote_box}/ #{local_folder}")
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
    if rsynced_clean && move_if_finished && move_if_finished.is_a?(Array)
      move_if_finished.each do |m|
        next unless m.is_a?(Array)
        next unless FileTest.directory?(m[0])
        Dir.mkdir(m[1]) unless FileTest.directory?(m[1])
        $speaker.speak_up("Moving #{m[0]} folder to #{m[1]}")
        FileUtils.mv(Dir.glob("#{m[0]}/*"), m[1]) rescue nil
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
    if !Utils.check_if_inactive(active_hours) && reverse_folder && reverse_folder.is_a?(Array)
      reverse_folder.each do |f|
        reverse_box = "#{remote_user}@#{remote_server}:#{f}"
        $speaker.speak_up("Starting reverse folder synchronisation with #{reverse_box} - #{Time.now.utc}")
        Rsync.run("#{f}/", "#{reverse_box}", opts, ssh_opts['port'], ssh_opts['keys']) do |result|
          if result.success?
            result.changes.each do |change|
              $speaker.speak_up "#{change.filename} (#{change.summary})"
            end
          else
            $speaker.speak_up result.error
          end
        end
        $speaker.speak_up("Finished reverse folder synchronisation with #{reverse_box} - #{Time.now.utc}")
      end
    end
    compare_remote_files(path: local_folder, remote_server: remote_server, remote_user: remote_user, filter_criteria: {'days_newer' => 10, 'exclude_path' => exclude_folders}, ssh_opts: ssh_opts, no_prompt: 1) unless rsynced_clean || !Utils.check_if_inactive(active_hours)
    $speaker.speak_up("Finished media box synchronisation - #{Time.now.utc}")
    raise "Rsync failure" unless rsynced_clean
  end

  def self.generate_playlist(name, list)
    $speaker.speak_up("Generating playlist #{name}.m3u with #{list.count} elements")
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
    $speaker.speak_up('Parsing movie list, can take a long time...')
    self.parse_watch_list(source).each do |item|
      movie = item['movie']
      next if movie.nil? || movie['year'].nil? || Time.now.year < movie['year']
      imdb_movie = MediaInfo.moviedb_search(movie['title'], true).first
      movie['release_date'] = imdb_movie.release_date.gsub(/\(\w+\)/, '').to_date rescue movie['release_date'] = Date.new(movie['year'])
      next if movie['release_date'] >= Date.today
      movies << movie
      print '...'
    end
    movies.sort_by! { |m| m['release_date'] }
    movies.each do |movie|
      break if break_processing(no_prompt)
      next if skip_loop_item("Do you want to look for releases of movie #{movie['title'].to_s + ' (' + movie['year'].to_s + ')'} (released on #{movie['release_date']})? (y/n)", no_prompt) > 0
      self.duplicate_search(dest_folder, movie['title'], [nil, nil], no_prompt, type)
      found = TorrentSearch.search(keywords: (movie['title'].to_s + ' ' + movie['year'].to_s + ' ' + extra_keywords).gsub(/[:,-\/\[\]]/, ''), limit: 10, category: 'movies', no_prompt: no_prompt, filter_dead: 1, move_completed: dest_folder, rename_main: movie['title'].to_s + ' (' + movie['year'].to_s + ')', main_only: 1)
      $cleanup_trakt_list << {:id => found, :c => [movie], :t => 'movies'} if found
    end
  rescue => e
    $speaker.tell_error(e, "Library.process_search_list")
  end

  def self.rename_tv_series(folder:, search_tvdb: 1, no_prompt: 0)
    qualities = Regexp.new('[ \.\(\)\-](' + VALID_QUALITIES.join('|') + ')')
    Utils.search_folder(folder, {'maxdepth' => 1, 'includedir' => 1}).each do |series|
      next unless File.directory?(series[0])
      begin
        series_name = File.basename(series[0])
        episodes = []
        if search_tvdb.to_i > 0
          go_on = 0
          tvdb_shows = $tvdb.search(series_name)
          tvdb_shows = $tvdb.search(series_name.gsub(/ \(\d{4}\)$/, '')) if tvdb_shows.empty?
          while go_on.to_i == 0
            tvdb_show = tvdb_shows.shift
            next if tvdb_show.nil?
            if tvdb_show['SeriesName'].downcase.gsub(/[ \(\)\.\:]/, '') == series_name.downcase.gsub(/[ \(\)\.\:]/, '')
              go_on = 1
            else
              go_on = $speaker.ask_if_needed("Found TVDB name #{tvdb_show['SeriesName']} for folder #{series_name}, proceed with that? (y/n)", no_prompt, 'y') == 'y' ? 1 : 0
            end
          end
          next unless go_on > 0
          unless tvdb_show.nil?
            show = $tvdb.get_series_by_id(tvdb_show['seriesid'])
            episodes = $tvdb.get_all_episodes(show)
          end
        end
        Utils.search_folder(series[0], {'regex' => '.*\.(mkv|avi|mp4)'}).each do |ep|
          ep_filename = File.basename(ep[0])
          identifiers = ep_filename.downcase.scan(/(^|[s\. _\^\[])(\d{1,3}[ex]\d{1,4})\&?([ex]\d{1,2})?/)
          identifiers = ep_filename.scan(/(^|[\. _\[])(\d{3,4})[\. _]/) if identifiers.empty?
          season = ''
          ep_nb = []
          unless identifiers.first.nil?
            identifiers.each do |m|
              bd = m[1].to_s.scan(/^(\d{1,3})[ex]/)
              if bd.first.nil?
                nb2 = 0
                case m[1].to_s.length
                  when 3
                    season = m[1].to_s.gsub(/^(\d)\d+/, '\1') if season == ''
                    nb = m[1].gsub(/^\d(\d+)/, '\1').to_i
                  when 4
                    season = m[1].to_s.gsub(/^(\d{2})\d+/, '\1') if season == ''
                    nb = m[1].gsub(/^\d{2}(\d+)/, '\1').to_i
                  else
                    nb = 0
                end
              else
                season = bd.first[0].to_s.to_i if season == ''
                nb = m[1].gsub(/\d{1,3}[ex](\d{1,4})/, '\1')
                nb2 = m[2].gsub(/[ex](\d{1,4})/, '\1') if m[2].to_s != ''
              end
              ep_nb << nb.to_i if nb.to_i > 0
              ep_nb << nb2.to_i if nb2.to_i > 0
            end
          end
          if season == '' || ep_nb.empty?
            season = $speaker.ask_if_needed("Season number not recognized for #{ep_filename}, please enter the season number now (empty to skip)", no_prompt, '').to_i
            ep_nb = [$speaker.ask_if_needed("Episode number not recognized for #{ep_filename}, please enter the episode number now (empty to skip)", no_prompt, '').to_i]
          end
          q = ep_filename.downcase.gsub('-', '').scan(qualities).join('.').gsub('-','')
          tvdb_ep_name = []
          ep_nb.each do |n|
            tvdb_ep = !episodes.empty? && season != '' && ep_nb.first.to_i > 0 ? episodes.select { |e| e.season_number == season.to_i.to_s && e.number == n.to_s }.first : nil
            tvdb_ep_name << (tvdb_ep.nil? ? '' : tvdb_ep.name)
          end
          tvdb_ep_name = tvdb_ep_name.join('.')[0..50]
          extension = ep_filename.gsub(/.*\.(\w{2,4}$)/, '\1')
          new_name = "#{series_name.downcase.gsub(/[ \:\,\-\[\]\(\)]/, '.')}."
          new_identifier = ''
          ep_nb.each do |n|
            new_identifier += "S#{format('%02d', season.to_i)}E#{format('%02d', n)}." if n.to_i > 0
          end
          new_name += "#{new_identifier}#{tvdb_ep_name.downcase.gsub(/[ \:\,\-\[\]\(\)]/, '.')}.#{q}.#{extension.downcase}"
          new_name = $speaker.ask_if_needed("File #{ep_filename} has not been recognized
          Please enter the new file name (empty to skip)?", no_prompt, '') if new_identifier == ''
          if new_name != '' && new_identifier != ''
            new_name = new_name.gsub(/\.\.+/, '.').gsub(/[\'\"\;\:\/]/,'')
            if File.exists?(File.dirname(ep[0]) + '/' + new_name)
              $speaker.speak_up("File #{ep_filename} is correctly named, skipping...")
            else
              $speaker.speak_up("Moving '#{ep_filename}' to '#{new_name}'")
              FileUtils.mv(ep[0], File.dirname(ep[0]) + '/' + new_name)
            end
          end
        end
      rescue => e
        $speaker.tell_error(e, "Rename tv series block #{series_name}")
      end
    end
  end

  def self.replace_movies(folder:, imdb_name_check: 1, filter_criteria: {}, extra_keywords: '', no_prompt: 0)
    $move_completed_torrent = folder
    Utils.search_folder(folder, filter_criteria).each do |film|
      next if already_processed?(film[1])
      next if File.basename(folder) == film[1]
      break if break_processing(no_prompt)
      path = film[0]
      titles = [[film[1], '']]
      next if skip_loop_item("Replace #{film[1]} (file is #{File.basename(path)})? (y/n)", no_prompt) > 0
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
        replaced = self.duplicate_search(folder, t[0], film, no_prompt, 'movies') if found
        break if replaced
        $speaker.speak_up("Looking for torrent of film #{t[0]}#{' (info IMDB: ' + URI.escape(t[1]) + ')' if t[1].to_s != ''}") unless no_prompt > 0 && !found
        replaced = no_prompt > 0 && !found ? nil : TorrentSearch.search(keywords: t[0] + ' ' + extra_keywords, limit: 10, category: 'movies', no_prompt: no_prompt, filter_dead: 1, move_completed: folder, rename_main: t[0], main_only: 1)
        break if replaced
        cpt += 1
      end
      $dir_to_delete << {:id => found, :d => File.dirname(path).gsub(folder, '')} if replaced.to_i > 0
    end
  rescue => e
    $speaker.tell_error(e, "Library.replace_movies")
  end

end
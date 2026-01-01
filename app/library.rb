require 'csv'
require_relative 'local_media_repository'

class Library
  include MediaLibrarian::AppContainerSupport

  @refusal = 0

  def self.break_processing(no_prompt = 0, threshold = 3)
    if @refusal > threshold
      @refusal = 0
      return app.speaker.ask_if_needed("Do you want to stop processing the list now? (y/n)", no_prompt, 'n') == 'y'
    end
    false
  end

  def self.skip_loop_item(question, no_prompt = 0)
    answer = app.speaker.ask_if_needed(question, no_prompt)
    @refusal = answer == 'y' ? 0 : @refusal + 1
    answer == 'y' ? 0 : 1
  end

  def self.convert_media(path:, input_format:, output_format:, no_warning: 0, rename_original: 1, move_destination: '', search_pattern: '', qualities: nil)
    dispatch_request(
      MediaLibrarian::Services::MediaConversionRequest,
      :convert,
      path: path,
      input_format: input_format,
      output_format: output_format,
      no_warning: no_warning,
      rename_original: rename_original,
      move_destination: move_destination,
      search_pattern: search_pattern,
      qualities: qualities
    )
  end

  def self.compare_remote_files(path:, remote_server:, remote_user:, filter_criteria: {}, ssh_opts: {}, no_prompt: 0)
    dispatch_request(
      MediaLibrarian::Services::RemoteComparisonRequest,
      :compare_remote_files,
      path: path,
      remote_server: remote_server,
      remote_user: remote_user,
      filter_criteria: filter_criteria,
      ssh_opts: ssh_opts,
      no_prompt: no_prompt
    )
  end

  def self.create_custom_list(name:, description:, origin: 'collection', criteria: {}, no_prompt: 0)
    dispatch_request(
      MediaLibrarian::Services::CustomListRequest,
      :create_custom_list,
      name: name,
      description: description,
      origin: origin,
      criteria: criteria,
      no_prompt: no_prompt
    )
  end

  def self.fetch_media_box(local_folder:, remote_user:, remote_server:, remote_folder:, clean_remote_folder: [], bandwith_limit: 0, active_hours: {}, ssh_opts: {}, exclude_folders_in_check: [], monitor_options: {})
    dispatch_request(
      MediaLibrarian::Services::RemoteFetchRequest,
      :fetch_media_box,
      local_folder: local_folder,
      remote_user: remote_user,
      remote_server: remote_server,
      remote_folder: remote_folder,
      clean_remote_folder: clean_remote_folder,
      bandwith_limit: bandwith_limit,
      ssh_opts: ssh_opts,
      active_hours: active_hours,
      exclude_folders_in_check: exclude_folders_in_check,
      monitor_options: monitor_options
    )
  end

  def self.fetch_media_box_core(local_folder, remote_user, remote_server, remote_folder, clean_remote_folder = [], bandwith_limit = 0, ssh_opts = {}, active_hours = {}, exclude_folders = [])
    remote_sync_service.fetch_media_box_core(local_folder, remote_user, remote_server, remote_folder, clean_remote_folder, bandwith_limit, ssh_opts, active_hours, exclude_folders)
  end

  def self.get_duplicates(medium, threshold = 2)
    # TODO: Better detection of duplicates media (in case of multi episodes file). But how to tackle it?
    return [] if medium.nil? || medium[:files].nil?
    dup_files = medium[:files].select { |x| x[:type].to_s == 'file' }.group_by { |a| a[:parts].join }.select { |_, v| v.count >= threshold }.map { |_, v| v }.flatten
    dup_files.select! do |x|
      x[:type].to_s == 'file' &&
        File.exist?(x[:name]) && # You never know...
        !Quality.parse_qualities(x[:name], EXTRA_TAGS, medium[:language], medium[:type]).include?('nodup') # We might want to keep several copies of a medium
    end
    return [] unless dup_files.count >= threshold
    Quality.sort_media_files(dup_files, {}, medium[:language], medium[:type])
  end

  def self.get_search_list(source_type, category, source, no_prompt = 0)
    dispatch_request(
      MediaLibrarian::Services::SearchListRequest,
      :get_search_list,
      source_type: source_type,
      category: category,
      source: source,
      no_prompt: no_prompt
    )
  end

  def self.handle_completed_download(torrent_path:, torrent_name:, completed_folder:, destination_folder:, torrent_id: "", handling: {}, remove_duplicates: 0, folder_hierarchy: FOLDER_HIERARCHY, force_process: 0, root_process: 1, ensure_qualities: '', move_completed_torrent: {}, exclude_path: ['extfls'])
    return app.speaker.speak_up "Torrent files not in completed folder, nothing to do!" if !torrent_path.include?(completed_folder) || completed_folder.to_s == ''
    completion_time = Time.now
    if root_process.to_i > 0
      opath = torrent_path.dup
      if move_completed_torrent['torrent_completed_path'].to_s != '' && torrent_id.to_s != ''
        t = app.db.get_rows('torrents', { :torrent_id => torrent_id }).first
        if t.nil? || t[:status].to_i < 5
          if move_completed_torrent['completed_torrent_local_cache'].to_s != '' && File.exist?(torrent_path + '/' + torrent_name) && !torrent_path.include?(move_completed_torrent['torrent_completed_path'].to_s)
            FileUtils.mkdir_p(torrent_path.gsub(completed_folder, move_completed_torrent['completed_torrent_local_cache'].to_s + '/').to_s)
            FileUtils.mv(torrent_path + '/' + torrent_name, torrent_path.gsub(completed_folder, move_completed_torrent['completed_torrent_local_cache'].to_s + '/').to_s)
          end
          opath = torrent_path.gsub!(completed_folder, move_completed_torrent['torrent_completed_path'].to_s + '/').to_s
          app.t_client.move_storage([torrent_id], opath) rescue nil
          app.speaker.speak_up "Waiting for storage file to be moved" if Env.debug?
          while FileUtils.is_in_path([app.t_client.get_torrent_status(torrent_id, ['save_path'])['save_path'].to_s], StringUtils.accents_clear(opath)).nil?
            break if Time.now - completion_time > 3600
            sleep 60
          end
          app.speaker.speak_up "Torrent storage moved to #{move_completed_torrent['torrent_completed_path']}" if Env.debug?
          completed_folder = move_completed_torrent['torrent_completed_path'].to_s
        end
      end
      if completed_folder != move_completed_torrent['torrent_completed_path'].to_s
        FileUtils.ln_r(torrent_path.dup + '/' + torrent_name, torrent_path.gsub!(completed_folder, app.temp_dir + '/') + '/' + torrent_name)
        completed_folder = app.temp_dir
      end
      opath += +'/' + torrent_name
    end
    full_p = (torrent_path + '/' + torrent_name).gsub(/\/\/*/, '/')
    handled, process_folder_list, error = 0, [], 0
    handled_files = (
      if handling['file_types'].is_a?(Array)
        handling['file_types'].map { |o| o.is_a?(Hash) ? o.map { |k, _| k.downcase } : o.downcase } + ['rar', 'zip']
      else
        ['rar', 'zip']
      end).flatten
    if FileTest.directory?(full_p)
      ensure_qualities = Quality.qualities_merge(ensure_qualities, full_p)
      FileUtils.search_folder(full_p, { 'exclude' => '.tmp.', 'exclude_path' => exclude_path, 'includedir' => 1, 'maxdepth' => 1 }).each do |f|
        hcd = handle_completed_download(
          torrent_path: File.dirname(f[0]),
          torrent_name: File.basename(f[0]),
          completed_folder: completed_folder,
          destination_folder: destination_folder,
          handling: handling,
          remove_duplicates: remove_duplicates,
          folder_hierarchy: Hash[folder_hierarchy.map { |k, v| [k, v.to_i + 1] }],
          force_process: force_process,
          root_process: 0,
          ensure_qualities: ensure_qualities,
          move_completed_torrent: move_completed_torrent,
          exclude_path: exclude_path
        )
        handled += hcd[0]
        error += hcd[2]
        process_folder_list += hcd[1]
      end
    elsif full_p.match(Regexp.new('.*\.(' + handled_files.join('|') + '$)').to_s)
      app.speaker.speak_up "Handling downloaded file '#{full_p}', ensuring qualities '#{ensure_qualities}'" if Env.debug?
      FileUtils.touch(full_p)
      otype = full_p.gsub(Regexp.new("^#{completed_folder}\/?([a-zA-Z1-9 _-]*)\/.*"), '\1')
      type = otype.downcase
      ttype = handling[type] && handling[type]['media_type'] ? handling[type]['media_type'] : type
      extension = FileUtils.get_extension(torrent_name)
      if ['rar', 'zip'].include?(extension)
        FileUtils.rm_r(torrent_path + '/extfls') if File.exist?(torrent_path + '/extfls')
        FileUtils.extract_archive(extension, full_p, torrent_path + '/extfls')
        ensure_qualities = Quality.parse_qualities(torrent_name, VALID_QUALITIES, '', ttype).join('.') if ensure_qualities.to_s == ''
        hcd = handle_completed_download(
          torrent_path: torrent_path,
          torrent_name: 'extfls',
          completed_folder: completed_folder,
          destination_folder: destination_folder,
          handling: handling,
          remove_duplicates: remove_duplicates,
          folder_hierarchy: Hash[folder_hierarchy.map { |k, v| [k, v.to_i + 1] }],
          force_process: force_process,
          root_process: 0,
          ensure_qualities: ensure_qualities,
          move_completed_torrent: move_completed_torrent,
          exclude_path: exclude_path - ['extfls']
        )
        handled += hcd[0]
        error += hcd[2]
        process_folder_list += hcd[1]
        Thread.current[:block] << Proc.new { FileUtils.rm_r(torrent_path + '/extfls') }
      elsif handling['file_types']
        if force_process.to_i == 0 && !handled_files.include?(extension)
          app.speaker.speak_up "Unsupported extension '#{extension}'"
          return handled, process_folder_list, error
        end
        args = handling['file_types'].select { |x| x.is_a?(Hash) && x[extension] }.first
        if File.basename(File.dirname(full_p)).downcase == 'sample' || File.basename(full_p).match(/([\. -])?sample([\. -])?/)
          app.speaker.speak_up 'File is a sample, skipping...'
          return handled, process_folder_list, error
        end
        if File.stat(full_p).nlink > 2
          app.speaker.speak_up 'File is already hard linked, skipping...'
          return handled, process_folder_list, error
        end
        if args && args[extension] && args[extension]['convert_to'].to_s != ''
          convert_media(
            path: full_p,
            input_format: extension,
            output_format: args[extension]['convert_to'],
            no_warning: 1,
            rename_original: 0,
            move_destination: File.dirname(full_p)
          ).each do |nf|
            hcd = handle_completed_download(
              torrent_path: File.dirname(nf),
              torrent_name: File.basename(nf),
              completed_folder: completed_folder,
              destination_folder: destination_folder,
              handling: handling,
              remove_duplicates: remove_duplicates,
              folder_hierarchy: folder_hierarchy,
              force_process: force_process,
              root_process: 0,
              ensure_qualities: ensure_qualities,
              move_completed_torrent: move_completed_torrent,
              exclude_path: exclude_path
            )
            handled += hcd[0]
            error += hcd[2]
            process_folder_list += hcd[1]
          end
        elsif handling[type] && handling[type]['move_to']
          if completed_folder == move_completed_torrent['torrent_completed_path'].to_s && move_completed_torrent['replace_destination_folder'].to_s != ''
            handling[type]['move_to'].gsub!(destination_folder, move_completed_torrent['replace_destination_folder'].to_s)
          end
          if handling[type] && handling[type]['no_hdr'].to_i > 0 && torrent_name.match(Regexp.new(VALID_VIDEO_EXT))
            media_info = FileInfo.new(full_p)
            if media_info.isHDR?
              media_info.hdr_to_sdr("#{full_p}.tmp.#{extension}")
              if handling[type]['no_hdr'].to_i > 1
                rename_media_file(full_p, handling[type]['move_to'], ttype, '', nil, 1, 1, 1, folder_hierarchy, ensure_qualities + '.hdr.nodup.', completed_folder + '/' + otype)
              else
                FileUtils.rm(full_p)
              end
              FileUtils.mv("#{full_p}.tmp.#{extension}", full_p.gsub!(".#{extension}", ".converted.#{extension}"))
            end
          end
          destination = rename_media_file(full_p, handling[type]['move_to'], ttype, '', nil, 1, 1, 1, folder_hierarchy, ensure_qualities, completed_folder + '/' + otype)
        else
          destination = full_p.gsub(completed_folder, destination_folder)
          _, moved = FileUtils.move_file(full_p, destination, 1)
          error += 1 unless moved
        end
        if defined?(destination) && destination.to_s != ''
          process_folder_list << [ttype, File.dirname(destination)]
          handled = 1
        end
      elsif Env.debug?
        app.speaker.speak_up 'File type not handled, skipping...'
      end
    end
    if root_process.to_i > 0
      FileUtils.rm_r(full_p) if completed_folder != move_completed_torrent['torrent_completed_path'].to_s
      raise 'Could not find any file to handle!' if handled == 0
      raise "An error occured" if error.to_i > 0
      process_folder_list.uniq.each do |p|
        process_folder(type: p[0], folder: p[1], remove_duplicates: 1, no_prompt: 1, cache_expiration: 1)
      end
      if torrent_id.to_s != ""
        active_time = (app.t_client.get_torrent_status(torrent_id, ['name', 'active_time']) rescue {})['active_time'].to_i
        Cache.queue_state_add_or_update('deluge_torrents_completed', { torrent_id => { :path => opath, :active_time => active_time } })
      end
    end
    return handled, process_folder_list, error
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding))
    if root_process.to_i > 0
      FileUtils.rm_r(full_p) if defined?(full_p) && full_p.to_s.include?(app.temp_dir)
      raise e
    end
    return handled, process_folder_list, 1
  end

  def self.handle_duplicates(files, remove_duplicates = 0, no_prompt = 0)
    files.each do |id, f|
      dup_files = get_duplicates(f)
      next unless dup_files.count > 0
      app.speaker.speak_up("Duplicate files found for #{f[:full_name]}")
      langs = []
      dup_files.select! do |d|
        app.speaker.speak_up("'#{d[:name]}'")
        to_rm = no_prompt.to_i == 0 || (dup_files.index(d) > 0 && (Quality.parse_qualities(d[:name], LANGUAGES) - langs).empty?)
        langs += Quality.parse_qualities(d[:name], LANGUAGES)
        to_rm
      end
      unless remove_duplicates.to_i <= 0 || dup_files.count == 0
        app.speaker.speak_up('Will now remove duplicates')
        dup_files.each do |d|
          if app.speaker.ask_if_needed("Remove file #{d[:name]}? (y/n)", no_prompt.to_i, 'y').to_s == 'y'
            FileUtils.rm(d[:name])
            files[id][:files].select! { |x| x[:name].to_s != d[:name] }
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
          Quality.qualities_file_filter(f, qualities)
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
    item_name, item = Metadata.identify_title(file[:name], type, no_prompt, (folder_hierarchy[type] || FOLDER_HIERARCHY[type]), base_folder, ids) unless item && item_name.to_s != ''
    unless (no_prompt.to_i == 0 && item_name.to_s != '') || item
      if Env.debug?
        app.speaker.speak_up("File '#{File.basename(file[:name])}' not identified, skipping. (folder_hierarchy='#{folder_hierarchy}', base_folder='#{base_folder}', ids='#{ids}')")
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
                                 folder_hierarchy
      )
      file[:name] = f_path unless f_path == ''
    end
    full_name, identifiers, info = Metadata.parse_media_filename(
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
    return files if file[:type].to_s == 'file' && !File.exist?(file[:name])
    app.speaker.speak_up("Adding #{file[:type]} '#{full_name}' (filename '#{File.basename(file[:name])}', ids '#{identifiers}') to list", 0) if Env.debug?
    if file[:type].to_s == 'file'
      Cache.queue_state_get('file_handling').each do |i, fs|
        if i.to_s != '' && identifiers.join.include?(i.to_s) && !fs.empty? && !fs.map { |obj| obj[:name] if obj[:type] == 'file' }.compact.include?(file[:name])
          Utils.lock_block("file_handling_found_#{i}") do
            ok = false
            fs.uniq.each do |f|
              app.speaker.speak_up "Found a '#{f[:type]}'#{' (' + f[:name].to_s + ')' if [:type] == 'file'} to remove for file '#{File.basename(file[:name])}' (identifier '#{i}'), removing now..." # if Env.debug?
              ok = !File.exist?(f[:name]) || FileUtils.rm(f[:name]) if f[:type] == 'file'
              if f[:type] == 'lists'
                imdb_id = (f[:imdb_id] || f[:external_id] || f[:obj_imdb]).to_s.strip
                watchlist_type = f[:obj_type] || f[:f_type]
                ok = WatchlistStore.delete(imdb_id: imdb_id, type: watchlist_type) if imdb_id != ''
              end
            end
            Cache.queue_state_remove('file_handling', i) if ok
          end
        end
      end
    end
    files = Metadata.media_add(item_name,
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
      app.speaker.speak_up("Invalid source")
      return {}, {}
    end
    search_list = {}
    existing_files = {}
    missing = {}
    case source_type
    when 'watchlist', 'download_list', 'lists'
      entries = WatchlistStore.fetch_with_details(type: category)
      app.speaker.speak_up('No entries found in watchlist') if entries.empty?
      entries.each do |row|
        type = Utils.regularise_media_type((row[:type] || row['type'] || category).to_s)
        next unless type.to_s == category.to_s

        imdb_id = (row[:imdb_id] || row['imdb_id']).to_s.strip
        ids = (row[:ids] || row['ids'] || {}).each_with_object({}) { |(k, v), memo| memo[k.to_s] = v }
        ids['imdb'] ||= imdb_id unless imdb_id.empty?
        title = (row[:title] || row['title'] || imdb_id).to_s
        next if title.empty?

        year = row[:year] || row['year']
        url = row[:url] || row['url']
        attrs = {
          obj_title: title,
          obj_year: year,
          obj_url: url,
          watchlist: 1,
          external_id: imdb_id,
        }
        name = type == 'movies' && year.to_i > 0 ? "#{title} (#{year})" : title
        search_list = parse_media(
          { :type => 'watchlist', :name => name },
          type,
          no_prompt,
          search_list,
          {},
          {},
          attrs,
          '',
          ids
        )
      end
      existing_files[category] = existing_media_from_db(category)
    when 'search'
      keywords = source['keywords']
      keywords = [keywords] if keywords.is_a?(String)
      keywords.each do |keyword|
        search_list = parse_media(
          { :type => 'keyword', :name => keyword },
          category,
          no_prompt,
          search_list,
          {},
          {},
          { :rename_main => source[:rename_main],
            :main_only => source[:main_only].to_i,
            :move_completed => (destination[category] || File.dirname(DEFAULT_MEDIA_DESTINATION[category])) }
        )
      end
    when 'local_files', 'trakt', 'lists'
      existing_files, search_list = get_search_list(source_type, category, source, no_prompt)
      search_list.keys.each do |id|
        app.speaker.speak_up(id) #REMOVEME
        next if id.is_a?(Symbol)
        case category
        when 'movies'
          search_list[id][:files] = [] unless search_list[id][:files].is_a?(Array)
          already_exists = get_duplicates(existing_files[category][id], 1)
          already_exists.each do |ae|
            if app.speaker.ask_if_needed("Replace already existing file #{ae[:name]}? (y/n)", no_prompt.to_i, source_type == 'trakt' ? 'n' : 'y').to_s == 'y'
              search_list[id][:files] << ae unless source_type == 'local_files'
            elsif app.speaker.ask_if_needed("Remove #{search_list[id][:name]} from the search list? (y/n)", no_prompt.to_i, 'y').to_s == 'y'
              search_list.delete(id)
            end
          end
        when 'shows'
          search_list.delete(id)
        end
      end
      missing[category] = list_missing_media(
        category,
        existing_files[category],
        no_prompt,
        (source['delta'] || 10),
        source['include_specials'],
        {}
      )
      ['movies', 'shows'].each { |t| search_list.merge!(missing[t]) if missing[t] }
      search_list.keep_if { |_, f| !f.is_a?(Hash) || f[:type] != 'movies' || (!f[:release_date].nil? && f[:release_date] < Time.now) }
    end
    return search_list, existing_files
  end

  def self.process_folder(type:, folder:, item_name: '', remove_duplicates: 0, rename: {}, filter_criteria: {}, no_prompt: 0, folder_hierarchy: {}, cache_expiration: CACHING_TTL)
    app.speaker.speak_up("Processing folder #{folder}...#{' for ' + item_name.to_s if item_name.to_s != ''}#{'(type: ' + type.to_s + ', folder: ' + folder.to_s + ', item_name: ' + item_name.to_s + ', remove_duplicates: ' + remove_duplicates.to_s + ', rename: ' + rename.to_s + ', filter_criteria: ' + filter_criteria.to_s + ', no_prompt: ' + no_prompt.to_s + ', folder_hierarchy: ' + folder_hierarchy.to_s + ')' if Env.debug?}", 0)
    files, raw_filtered, cache_name, media_list = nil, [], folder.to_s + type.to_s, {}
    file_criteria = { 'regex' => '.*' + item_name.to_s.gsub(/(\w*)\(\d+\)/, '\1').strip.gsub(/ /, '.') + '.*' }
    raw_filtered += FileUtils.search_folder(folder, filter_criteria.merge(file_criteria)) if filter_criteria && !filter_criteria.empty?
    Utils.lock_block(__method__.to_s + cache_name) {
      media_list = BusVariable.new('media_list', Vash)
      if media_list[cache_name].nil? || remove_duplicates.to_i > 0 || (rename && !rename.empty?)
        FileUtils.search_folder(folder, file_criteria.deep_merge(DEFAULT_FILTER_PROCESSFOLDER[type]) { |_, x1, x2| x1 + x2 }).each do |f|
          next unless f[0].match(Regexp.new(VALID_VIDEO_EXT))
          Librarian.route_cmd(
            ['Library', 'parse_media', { :type => 'file', :name => f[0] }, type, no_prompt, {}, folder_hierarchy, rename, {}, folder],
            1,
            Thread.current[:object],
            8
          )
        end
        media_list[cache_name, cache_expiration.to_i] = Daemon.consolidate_children
        media_list[cache_name, cache_expiration.to_i] = handle_duplicates(media_list[cache_name] || {}, remove_duplicates, no_prompt)
      elsif Env.debug?
        app.speaker.speak_up("Cache of media_list [#{cache_name}] exists, returning it directly", 0)
      end
    }
    if filter_criteria && !filter_criteria.empty? && !media_list[cache_name].empty?
      files = media_list[cache_name].dup
      files.keep_if { |k, f| !k.is_a?(Symbol) && !(f[:files].map { |x| x[:name] } & raw_filtered.flatten).empty? }
    end
    app.speaker.speak_up("Finished processing folder #{folder}.")
    return files || media_list[cache_name]
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding))
    media_list.delete(cache_name)
    {}
  end

  def self.existing_media_from_db(category, folder = nil)
    LocalMediaRepository.new(app: app).library_index(type: category, folder: folder) || {}
  end

  def self.rename_media_file(original, destination, type, item_name = '', item = nil, no_prompt = 0, hard_link = 0, replaced_outdated = 0, folder_hierarchy = {}, ensure_qualities = '', base_folder = Dir.home)
    app.speaker.speak_up Utils.arguments_dump(binding) if Env.debug?
    destination += "#{File.basename(original).gsub('.' + FileUtils.get_extension(original), '')}" if FileTest.directory?(destination)
    media_info = FileInfo.new(original)
    _, qualities = Quality.detect_file_quality(original, media_info, 0, ensure_qualities, type)
    metadata = Metadata.identify_metadata(original, type, item_name, item, no_prompt, folder_hierarchy, base_folder, qualities)
    destination = Utils.parse_filename_template(destination, metadata)
    if destination.to_s == ''
      app.speaker.speak_up "Destination of file '#{original}' is empty, skipping..."
      return ''
    end
    if !metadata.empty? && metadata['is_found']
      destination += ".#{metadata['part']}" if metadata['part'].to_s != ''
      destination += ".#{metadata['extension'].downcase}"
      _, destination = FileUtils.move_file(original, destination, hard_link, replaced_outdated, no_prompt)
      raise "Error moving file" if destination.to_s == ''
    else
      app.speaker.speak_up "File '#{original}' not identified, skipping..."
      destination = ''
    end
    destination
  end

  # Import a CSV into the watchlist
  # Usage:
  #   Library.import_list_csv(list_name: 'to_download', csv_path: '/path/to/list.csv', replace: '1') # replace rows
  def self.import_list_csv(list_name: nil, csv_path: nil, replace: '1')
    begin
      raise ArgumentError, 'csv_path must be provided' if csv_path.to_s.strip.empty?
      raise ArgumentError, "CSV file not found: #{csv_path}" unless File.file?(csv_path)
      list_name = list_name.to_s.strip
      rows = []
      CSV.foreach(csv_path, headers: true) do |row|
        title = row['title']&.to_s&.strip
        imdb_id = (row['imdb_id'] || row['imdb'] || row['external_id'])&.to_s&.strip
        next if title.nil? || title.empty? || imdb_id.nil? || imdb_id.empty?

        type = Utils.regularise_media_type((row['type'] || 'movies').to_s)
        year = row['year']&.to_s&.strip
        year_i = (year && year =~ /^\d{4}$/) ? year.to_i : nil
        alts = row['alt_titles']&.to_s&.strip
        url = row['url']&.to_s&.strip
        tmdb = (row['tmdb_id'] || row['tmdb'])&.to_s&.strip
        metadata = {}
        metadata[:list_name] = list_name unless list_name.empty?
        metadata[:year] = year_i if year_i
        metadata[:alt_titles] = alts if alts && !alts.empty?
        metadata[:url] = url if url && !url.empty?
        metadata[:tmdb] = tmdb if tmdb && !tmdb.empty?
        rows << { imdb_id: imdb_id, title: title, type: type, metadata: metadata.empty? ? nil : metadata }
      end
      return 0 if rows.empty?

      count = WatchlistStore.upsert(rows)
      app.speaker.speak_up("import_list_csv: imported #{count} rows into watchlist", 0) if defined?(app.speaker)
      count
    rescue => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding), 0) rescue nil
      0
    end
  end

  class << self
    private

    def dispatch_request(request_class, service_method, **attrs)
      request = request_class.new(**attrs)
      service_for(request_class).public_send(service_method, request)
    end

    def service_for(request_class)
      {
        MediaLibrarian::Services::MediaConversionRequest => method(:media_conversion_service),
        MediaLibrarian::Services::RemoteComparisonRequest => method(:remote_sync_service),
        MediaLibrarian::Services::RemoteFetchRequest => method(:remote_sync_service),
        MediaLibrarian::Services::CustomListRequest => method(:list_management_service),
        MediaLibrarian::Services::SearchListRequest => method(:list_management_service)
      }.fetch(request_class).call
    end

    def media_conversion_service
      MediaLibrarian::Services::MediaConversionService.new(app: app)
    end

    def remote_sync_service
      MediaLibrarian::Services::RemoteSyncService.new(app: app)
    end

    def list_management_service
      MediaLibrarian::Services::ListManagementService.new(app: app)
    end
  end
end

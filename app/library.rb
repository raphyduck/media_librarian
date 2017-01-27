class Library

  def self.compare_remote_files(path, remote_server, remote_user, filter_criteria = {}, ssh_opts = {}, interactive = 1)
    ssh_opts = Utils.recursive_symbolize_keys(eval(ssh_opts)) if ssh_opts.is_a?(String)
    list = FileTest.directory?(path) ? self.search_folder(path, filter_criteria) : [[path, '']]
    list.each do |f|
      f_path = f[0]
      Speaker.speak_up("Comparing #{f_path} on local and remote #{remote_server}")
      local_md5sum = Utils.md5sum(f_path)
      remote_md5sum = ''
      Net::SSH.start(remote_server, remote_user, ssh_opts) do |ssh|
        remote_md5sum = []
        ssh.exec!("md5sum '#{f_path}'")
        ssh.exec!("md5sum '#{f_path}'") do |_, stream, data|
          remote_md5sum << data if stream == :stdout
        end
        remote_md5sum = remote_md5sum.first
        remote_md5sum = remote_md5sum ? remote_md5sum.gsub(/(\w*)( .*\n)/,'\1') : ''
      end
      Speaker.speak_up("Local md5sum is #{local_md5sum}")
      Speaker.speak_up("Remote md5sum is #{remote_md5sum}")
      if local_md5sum != remote_md5sum || local_md5sum == '' || remote_md5sum == ''
        Speaker.speak_up("Mismatch between the 2 files, the remote file might not exist or the local file is incorrectly downloaded")
        if local_md5sum != '' && remote_md5sum != '' && Speaker.ask_if_needed("Delete the local file? (y/n)", interactive, 'n') == 'y'
          FileUtils.rm_r(f_path)
        end
      else
        Speaker.speak_up("The 2 files are identical!")
        if Speaker.ask_if_needed("Delete the remote file? (y/n)", interactive, 'y') == 'y'
          Net::SSH.start(remote_server, remote_user, ssh_opts) do |ssh|
            ssh.exec!("rm '#{f_path}'")
          end
        end
      end
    end
  rescue => e
    Speaker.tell_error(e, "Library.compare_remote_files")
  end

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
          corrected_dups = []
          dups.each do |d|
            d_title = self.moviedb_search(File.basename(File.dirname(d)))
            corrected_dups << d if d_title == title
          end
          if Speaker.ask_if_needed("Duplicate(s) found for film #{title}. Duplicates are:#{NEW_LINE}" + corrected_dups.map{|d| "#{d[0]}#{NEW_LINE}"}.to_s + ' Do you want to remove them? (y/n)', interactive) == 'y'
            corrected_dups.each do |d|
              FileUtils.rm_r(d[0])
            end
          end
        end
      end
      Speaker.speak_up("Looking for torrent of film #{title}") unless interactive == 0 && !found
      replaced = interactive == 0 && !found ? false : T411Search.search(title + ' ' + quality_keyword, 10, 210, interactive, 1, folder, title, true)
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
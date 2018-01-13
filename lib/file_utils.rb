module FileUtils
  class << self
    include Sys
    alias_method :mkdir_orig, :mkdir
    alias_method :mkdir_p_orig, :mkdir_p
    alias_method :mv_orig, :mv
    alias_method :rm_orig, :rm
    alias_method :rm_r_orig, :rm_r
    alias_method :rmdir_orig, :rmdir
    alias_method :ln_orig, :ln

    def cleanup_folder
      Cache.queue_state_get('dir_to_delete').each do |f, _|
        next if f.to_s == '/'
        rm(f) if File.exist?(f)
        Cache.queue_state_remove('dir_to_delete', f)
      end
    end

    def compress_archive(folder, name)
      Dir.chdir(File.dirname(folder)) do
        if Env.pretend?
          $speaker.speak_up "Would compress the following files:"
          Dir.foreach('.') { |f| $speaker.speak_up f }
        else
          Archive::Zip.archive(name, File.basename(folder))
        end
      end
    end

    def extract_archive(type, archive, destination)
      FileUtils.mkdir(destination) unless Dir.exist?(destination)
      return $speaker.speak_up "Would extract archive #{type} '#{archive}' to '#{destination}'" if Env.pretend?
      case type
        when 'cbr', 'rar'
          $unrar = Unrar::Archive.new(archive, destination)
          extracted = $unrar.extract
          $speaker.speak_up("Extracted #{archive} to #{destination}") if extracted
        when 'cbz', 'zip'
          Archive::Zip.extract(archive, destination, {:ignore_check_flags => 1})
      end
    end

    def get_disk_size(path)
      size=0
      Find.find(path) { |file| size+= File.size(file)}
      size
    end

    def get_disk_space(path)
      stat = Sys::Filesystem.stat(path)
      return stat.block_size * stat.blocks_available, stat.blocks * stat.block_size
    end

    def get_only_folder_levels(path, level = 1)
      cpt = 0
      initial_f = path
      f = File.basename(path)
      while cpt <= level
        break if path == File.dirname(path)
        path = File.dirname(path)
        f = File.basename(path) + '/' + f
        cpt += 1
      end
      f.gsub!('//', '/')
      return f.gsub(/^\.\//, ''), initial_f.gsub(f, '')
    end

    def get_path_depth(path, folder)
      folder = File.absolute_path(folder)
      path = File.absolute_path(path)
      folder = folder + '/' unless folder[-1] == '/'
      return 0 unless path.include?(folder)
      parent = File.dirname(path.gsub(folder, ''))
      if parent == '.'
        1
      else
        1 + get_path_depth(File.dirname(path), folder)
      end
    end

    def get_top_folder(path)
      return path.gsub(/^\/?([^\/]*)\/.*/, '\1').to_s, path.gsub(/^\/?([^\/]*)\//, '').to_s
    end

    def is_in_path(path_list, folder)
      path_list.each do |p|
        return p if folder.gsub('//', '/').include?(p.gsub('//', '/')) || p.gsub('//', '/').include?(folder.gsub('//', '/'))
      end
      return nil
    rescue => e
      $speaker.tell_error(e, "FileUtils.is_in_path(#{path_list}, #{folder}")
      nil
    end

    def ln(original, destination)
      return $speaker.speak_up("Would ln #{original} to #{destination}") if Env.pretend?
      $speaker.speak_up("ln #{original} #{destination}") if Env.debug?
      ln_orig(original, destination)
    end

    def md5sum(file)
      md5 = File.open(file, 'rb') do |io|
        dig = Digest::MD5.new
        buf = ""
        dig.update(buf) while io.read(4096, buf)
        dig
      end
      md5.to_s
    end

    def mkdir(dirs)
      return $speaker.speak_up("Would mkdir #{dirs}") if Env.pretend?
      $speaker.speak_up("mkdir #{dirs}") if Env.debug?
      mkdir_orig(dirs)
    end

    def mkdir_p(dirs)
      return $speaker.speak_up("Would mkdir_p #{dirs}") if Env.pretend?
      $speaker.speak_up("mkdir_p #{dirs}") if Env.debug?
      mkdir_p_orig(dirs)
    end

    def move_file(original, destination, hard_link = 0, remove_outdated = 0)
      destination = destination.gsub(/\.\.+/, '.').gsub(/[\'\"\;\:]/, '')
      if File.exists?(destination)
        _, prosper = MediaInfo.identify_proper(original)
        if remove_outdated.to_i > 0 && prosper.to_i > 0
          $speaker.speak_up("File #{File.basename(original)} is an upgrade release, replacing existing file #{File.basename(destination)}.")
          rm(destination)
        else
          $speaker.speak_up("File #{File.basename(destination)} is correctly named, skipping...", 0)
          return false, destination
        end
      end
      $speaker.speak_up("#{hard_link.to_i > 0 ? 'Linking' : 'Moving'} '#{original}' to '#{destination}'")
      mkdir_p(File.dirname(destination)) unless Dir.exist?(File.dirname(destination))
      if hard_link.to_i > 0
        ln(original, destination)
      else
        mv(original, destination)
      end
      return true, destination
    rescue => e
      $speaker.tell_error(e, 'utils.move_file')
      return false, ''
    end

    def file_remove_parents(files)
      files = [files] if files.is_a?(String)
      files.each do |f|
        rm_r(File.dirname(f)) if (Dir.entries(File.dirname(f)).select { |e| e.match(Regexp.new('\.(' + IRRELEVANT_EXTENSIONS.join('|') + ')$')).nil? } - %w{ . .. }).empty?
      end
    end

    def mv(original, destination)
      return $speaker.speak_up("Would mv #{original} #{destination}") if Env.pretend?
      $speaker.speak_up("mv #{original} #{destination}") if Env.debug?
      mv_orig(original, destination)
    end

    def rm(files)
      if Env.pretend?
        $speaker.speak_up("Would rm #{files}") if files.is_a?(Array) || files.to_s != ''
      else
        rm_orig(files) if files.is_a?(Array) || files.to_s != ''
      end
      $speaker.speak_up("rm #{files}") if Env.debug?
      file_remove_parents(files)
    end

    def rm_r(files)
      if Env.pretend?
        $speaker.speak_up("Would rm_r #{files}")
      else
        rm_r_orig(files)
      end
      $speaker.speak_up("rm_r #{files}") if Env.debug?
      file_remove_parents(files)
    end

    def rmdir(dirs)
      if Env.pretend?
        $speaker.speak_up("Would rmdir #{dirs}")
      else
        rmdir_orig(dirs)
      end
      $speaker.speak_up("rmdir #{dirs}") if Env.debug?
      file_remove_parents(dirs)
    end

    def search_folder(folder, filter_criteria = {})
      filter_criteria = {} if filter_criteria.nil?
      search_folder = []
      Find.find(folder).each do |path|
        path = File.absolute_path(path)
        next if path == File.absolute_path(folder)
        parent = File.basename(File.dirname(path))
        next unless File.exist?(path)
        depth = get_path_depth(path, folder)
        breakflag = 0
        breakflag = 1 if breakflag == 0 && FileTest.directory?(path) && !filter_criteria['includedir'] && !filter_criteria['dironly']
        breakflag = 1 if breakflag == 0 && !FileTest.directory?(path) && filter_criteria['dironly']
        breakflag = 1 if breakflag == 0 && filter_criteria['name'] && !File.basename(path).downcase.include?(filter_criteria['name'].downcase)
        breakflag = 1 if breakflag == 0 && filter_criteria['regex'] && !path.match(filter_criteria['regex'], Regexp::IGNORECASE)
        breakflag = 1 if breakflag == 0 && filter_criteria['exclude'] && File.basename(path).include?(filter_criteria['exclude'])
        breakflag = 1 if breakflag == 0 && filter_criteria['exclude_strict'] && File.basename(path) == filter_criteria['exclude_strict']
        breakflag = 1 if breakflag == 0 && filter_criteria['exclude_strict'] && parent == filter_criteria['exclude_strict']
        breakflag = 1 if breakflag == 0 && filter_criteria['days_older'].to_i > 0 && File.mtime(path) > Time.now - filter_criteria['days_older'].to_i.days
        breakflag = 1 if breakflag == 0 && filter_criteria['days_newer'].to_i > 0 && File.mtime(path) < Time.now - filter_criteria['days_newer'].to_i.days
        breakflag = 1 if breakflag == 0 && (filter_criteria['exclude_path'] && filter_criteria['exclude_path'].is_a?(Array) && is_in_path(filter_criteria['exclude_path'], path)) || path.include?('@eaDir')
        breakflag = 1 if breakflag == 0 && filter_criteria['str_closeness'].to_i > 0 && filter_criteria['str_closeness_comp'] &&
            $str_closeness.getDistance(File.basename(path), filter_criteria['str_closeness_comp']) < filter_criteria['str_closeness'].to_i &&
            $str_closeness.getDistance(parent, filter_criteria['str_closeness_comp']) < filter_criteria['str_closeness'].to_i
        search_folder << [path, parent] if breakflag == 0
        if filter_criteria['maxdepth'].to_i > 0 && depth >= filter_criteria['maxdepth'].to_i
          Find.prune if FileTest.directory?(path)
        end
        break if filter_criteria['return_first'] && breakflag == 0
      end
      search_folder
    rescue => e
      $speaker.tell_error(e, "FileUtils.search_folder")
      []
    end
  end
end
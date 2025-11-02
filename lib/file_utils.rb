require 'find'

module FileUtils
  class << self
    alias_method :mkdir_orig, :mkdir
    alias_method :mkdir_p_orig, :mkdir_p
    alias_method :mv_orig, :mv
    alias_method :rm_orig, :rm
    alias_method :rm_r_orig, :rm_r
    alias_method :rmdir_orig, :rmdir
    alias_method :ln_orig, :ln
    alias_method :cp_orig, :cp

    def compress_archive(folder, name)
      Dir.chdir(File.dirname(folder)) do
        if Env.pretend?
          MediaLibrarian.app.speaker.speak_up "Would compress the following files:"
          Dir.foreach('.') { |f| MediaLibrarian.app.speaker.speak_up f }
        else
          Archive::Zip.archive(name, File.basename(folder))
        end
      end
    end

    def cp(source, target)
      return MediaLibrarian.app.speaker.speak_up("Would cp #{source} to #{target}") if Env.pretend?
      MediaLibrarian.app.speaker.speak_up("cp #{source} #{target}") if Env.debug?
      rm(target) if File.exist?(target)
      mkdir_p(File.dirname(target)) unless File.exist?(File.dirname(target))
      MediaLibrarian.app.speaker.speak_up("File '#{source}' doesn't exist!") unless File.exist?(source)
      cp_orig(source, target)
    end

    def extract_archive(type, archive, destination)
      FileUtils.mkdir(destination) unless Dir.exist?(destination)
      return MediaLibrarian.app.speaker.speak_up "Would extract archive #{type} '#{archive}' to '#{destination}'" if Env.pretend?
      case type
      when 'cbr', 'rar'
        unrar = Unrar::Archive.new(archive, destination)
        extracted = unrar.extract
        MediaLibrarian.app.speaker.speak_up("Extracted #{archive} to #{destination}") if extracted
      when 'cbz', 'zip'
        Archive::Zip.extract(archive, destination, {:ignore_check_flags => 1})
      end
    end

    def get_disk_size(path)
      size = 0
      Find.find(path) { |file| size += File.size(file) }
      size
    end

    def get_disk_space(path)
      return `df --output=avail -k #{path} | tail -1`.to_i * 1024, `df --output=size -k #{path} | tail -1`.to_i * 1024
    rescue => e
      MediaLibrarian.app.speaker.tell_error(e, Utils.arguments_dump(binding), 0)
      return 0, 0
    end

    def get_extension(filename)
      ext = filename.gsub(/.*\.(\w{2,4}$)/, '\1').downcase
      ext.size != filename.size ? ext : ''
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

    def get_valid_extensions(type)
      EXTENSIONS_TYPE[Metadata.media_type_get(type)]
    end

    def is_in_path(path_list, folder)
      folder = folder.clone.gsub(/\/\/+/, '/').gsub(/^\//, '').gsub(/\/$/, '')
      path_list.each do |p|
        p = p.clone.gsub(/\/\/+/, '/').gsub(/^\//, '').gsub(/\/$/, '')
        if folder.match(/(\/|^)#{Regexp.escape(p)}(\/|$)/) || p.match(/(\/|^)#{Regexp.escape(folder)}(\/|$)/)
          return p
        end
      end
      return nil
    rescue => e
      MediaLibrarian.app.speaker.tell_error(e, Utils.arguments_dump(binding))
      nil
    end

    def ln(original, destination)
      return MediaLibrarian.app.speaker.speak_up("Would ln #{original} to #{destination}") if Env.pretend?
      MediaLibrarian.app.speaker.speak_up("ln #{original} #{destination}") if Env.debug?
      rm(destination) if File.exist?(destination)
      mkdir_p(File.dirname(destination)) unless File.exist?(File.dirname(destination))
      MediaLibrarian.app.speaker.speak_up("File '#{original}' doesn't exist!") unless File.exist?(original)
      begin
        ln_orig(original, destination)
      rescue => e
        MediaLibrarian.app.speaker.speak_up "Hard linking failed with error '#{e}', trying to copy instead" if Env.debug?
        cp(original, destination)
      end
    end

    def ln_r(source, target)
      MediaLibrarian.app.speaker.speak_up "ln_r copying and hard linking from #{source} to #{target}" if Env.debug?
      return ln(source, target) unless File.directory?(source)
      source = File.join(source, "")
      target = File.join(target, "")
      rm_r(target) if File.exist?(target)
      mkdir_p(target)
      Dir.glob(File.join(source.gsub("[","\\[").gsub("]","\\]"), '**/*')).each do |source_path|
        target_path = source_path.gsub(Regexp.new("^" + Regexp.escape(source)), target)
        if File.file? source_path
          mkdir_p File.dirname(target_path)
          ln(source_path, target_path)
        else
          mkdir_p target_path
        end
      end
      MediaLibrarian.app.speaker.speak_up "Done copying/linking." if Env.debug?
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
      return MediaLibrarian.app.speaker.speak_up("Would mkdir #{dirs}") if Env.pretend?
      MediaLibrarian.app.speaker.speak_up("mkdir #{dirs}") if Env.debug?
      mkdir_orig(dirs)
    end

    def mkdir_p(dirs)
      return MediaLibrarian.app.speaker.speak_up("Would mkdir_p #{dirs}") if Env.pretend?
      MediaLibrarian.app.speaker.speak_up("mkdir_p #{dirs}") if Env.debug?
      mkdir_p_orig(dirs)
    end

    def move_file(original, destination, hard_link = 0, remove_outdated = 0, no_prompt = 1)
      destination = destination.gsub(/\.\.+/, '.').gsub(/[\'\"\;\:]/, '')
      if File.exist?(destination)
        _, proper = Quality.identify_proper(original)
        if remove_outdated.to_i > 0 && proper.to_i > 0
          MediaLibrarian.app.speaker.speak_up("File #{File.basename(original)} is an upgrade release, replacing existing file #{File.basename(destination)}.")
          rm(destination)
        else
          MediaLibrarian.app.speaker.speak_up("File #{File.basename(destination)} is correctly named, skipping...", 0)
          return false, destination
        end
      end
      return if MediaLibrarian.app.speaker.ask_if_needed("Move '#{original}' to '#{destination}'? (y/n)", no_prompt, 'y').to_s != 'y'
      MediaLibrarian.app.speaker.speak_up("#{hard_link.to_i > 0 ? 'Linking' : 'Moving'} '#{original}' to '#{destination}'", 0)
      mkdir_p(File.dirname(destination)) unless Dir.exist?(File.dirname(destination))
      if hard_link.to_i > 0
        ln(original, destination)
      else
        mv(original, destination)
      end
      return true, destination
    rescue => e
      MediaLibrarian.app.speaker.tell_error(e, 'FileUtils.move_file')
      return false, ''
    end

    def file_remove_parents(files)
      files = [files] if files.is_a?(String)
      files.each do |f|
        rm_r(File.dirname(f)) if (Dir.entries(File.dirname(f)).select { |e| e.match(Regexp.new('\.(' + IRRELEVANT_EXTENSIONS.join('|') + ')$')).nil? } - %w{ . .. }).empty?
      end
    end

    def mv(original, destination)
      return MediaLibrarian.app.speaker.speak_up("Would mv #{original} #{destination}") if Env.pretend?
      MediaLibrarian.app.speaker.speak_up("mv #{original} #{destination}") if Env.debug?
      mv_orig(original, destination)
      file_remove_parents(original)
    end

    def rm(files, force: nil, noop: nil, verbose: nil)
      return MediaLibrarian.app.speaker.speak_up("Would rm #{files}") if files.is_a?(Array) || files.to_s != '' if Env.pretend?
      Utils.lock_block("file_utils_rm") do
        MediaLibrarian.app.speaker.speak_up("Removing file '#{files}'")
        rm_orig(files, force: force, noop: noop, verbose: verbose) if files.is_a?(Array) || files.to_s != ''
      end
      file_remove_parents(files)
      true
    end

    def rm_r(files, force: nil, noop: nil, verbose: nil, secure: nil)
      Utils.lock_block("file_utils_rm") do
        MediaLibrarian.app.speaker.speak_up("Removing file or directory '#{files}'")
        if Env.pretend?
          MediaLibrarian.app.speaker.speak_up("Would rm_r #{files}")
        else
          rm_r_orig(files, force: force, noop: noop, verbose: verbose, secure: secure)
        end
      end
      file_remove_parents(files)
    end

    def rmdir(dirs)
      MediaLibrarian.app.speaker.speak_up("rmdir #{dirs}") if Env.debug?
      if Env.pretend?
        MediaLibrarian.app.speaker.speak_up("Would rmdir #{dirs}")
      else
        rmdir_orig(dirs)
      end
      file_remove_parents(dirs)
    end

    def search_folder(folder, filter_criteria = {})
      MediaLibrarian.app.speaker.speak_up Utils.arguments_dump(binding) if Env.debug?
      filter_criteria = {} if filter_criteria.nil?
      return [] unless folder && File.directory?(folder)
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
        breakflag = 1 if breakflag == 0 && filter_criteria['regex'] && !path.match(Regexp.new(filter_criteria['regex'], Regexp::IGNORECASE))
        breakflag = 1 if breakflag == 0 && filter_criteria['exclude'] && File.basename(path).include?(filter_criteria['exclude'])
        breakflag = 1 if breakflag == 0 && filter_criteria['exclude_strict'] && File.basename(path) == filter_criteria['exclude_strict']
        breakflag = 1 if breakflag == 0 && filter_criteria['exclude_strict'] && parent == filter_criteria['exclude_strict']
        breakflag = 1 if breakflag == 0 && filter_criteria['days_older'].to_i > 0 && File.mtime(path) > Time.now - filter_criteria['days_older'].to_i.days
        breakflag = 1 if breakflag == 0 && filter_criteria['days_newer'].to_i > 0 && File.mtime(path) < Time.now - filter_criteria['days_newer'].to_i.days
        breakflag = 1 if breakflag == 0 && (filter_criteria['exclude_path'] && filter_criteria['exclude_path'].is_a?(Array) && is_in_path(filter_criteria['exclude_path'], path)) || path.include?('@eaDir')
        breakflag = 1 if breakflag == 0 && filter_criteria['str_closeness'].to_i > 0 && filter_criteria['str_closeness_comp'] &&
            MediaLibrarian.app.str_closeness.getDistance(File.basename(path), filter_criteria['str_closeness_comp']) < filter_criteria['str_closeness'].to_i &&
            MediaLibrarian.app.str_closeness.getDistance(parent, filter_criteria['str_closeness_comp']) < filter_criteria['str_closeness'].to_i
        search_folder << [path, parent] if breakflag == 0
        if filter_criteria['maxdepth'].to_i > 0 && depth >= filter_criteria['maxdepth'].to_i
          Find.prune if FileTest.directory?(path)
        end
        break if filter_criteria['return_first'] && breakflag == 0
      end
      search_folder
    rescue => e
      MediaLibrarian.app.speaker.tell_error(e, Utils.arguments_dump(binding))
      []
    end
  end
end
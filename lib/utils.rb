class Utils
  include Sys

  def self.bash(command)
    escaped_command = Shellwords.escape(command)
    system "bash -c #{escaped_command}"
  end

  def self.check_if_active(active_hours = {})
    !active_hours.is_a?(Hash) ||
        ((active_hours['start'].nil? || active_hours['start'].to_i < Time.now.hour) &&
            (active_hours['end'].nil? || active_hours['end'].to_i >= Time.now.hour))
  end

  def self.clean_search(str)
    str.gsub(/[,\']/, '')
  end

  def self.cleanup_folder
    $dir_to_delete.each do |f|
      next if f[:d].to_s == '' || f[:d].to_s == '/'
      Utils.file_rm(f[:d])
    end
  end

  def self.compress_archive(folder, name)
    pwd = Dir.pwd
    Dir.chdir(File.dirname(folder))
    Archive::Zip.archive(name, File.basename(folder))
    Dir.chdir(pwd)
  end

  def self.entry_deja_vu?(category, entry)
    dejavu = $db.get_rows('seen', {'category' => 'global', 'entry' => entry.downcase.gsub(' ', '')})
    dejavu = $db.get_rows('seen', {'category' => category, 'entry' => entry.downcase.gsub(' ', '')}) if dejavu.empty?
    dejavu = !dejavu.empty?
    $speaker.speak_up("#{category.to_s.titleize} entry #{entry} already seen") if dejavu
    dejavu
  end

  def self.entry_seen(category, entry)
    $db.insert_row('seen', {'category' => category, 'entry' => entry.downcase.gsub(' ', ''), 'created_at' => Time.now})
  end

  def self.extract_archive(type, archive, destination)
    Utils.file_mkdir(destination) unless Dir.exist?(destination)
    case type
      when 'cbr', 'rar'
        $unrar = Unrar::Archive.new(archive, destination)
        extracted = $unrar.extract
        $speaker.speak_up("Extracted #{archive} to #{destination}") if extracted
      when 'cbz', 'zip'
        Archive::Zip.extract(archive, destination)
    end
  end

  def self.file_mkdir(dirs)
    return $speaker.speak_up("Would mkdir #{dirs}") if $env_flags['pretend'] > 0
    FileUtils.mkdir(dirs)
  end

  def self.file_mkdir_p(dirs)
    return $speaker.speak_up("Would mkdir_p #{dirs}") if $env_flags['pretend'] > 0
    FileUtils.mkdir_p(dirs)
  end

  def self.file_remove_parents(files)
    files = [files] if files.is_a?(String)
    files.each do |f|
      file_rm_r(File.dirname(f)) if (Dir.entries(File.dirname(f)).select{|e| e.match(Regexp.new('\.(' + IRRELEVANT_EXTENSIONS.join('|') + ')$')).nil?} - %w{ . .. }).empty?
    end
  end

  def self.file_mv(original, destination)
    return $speaker.speak_up("Would mv #{original} #{destination}") if $env_flags['pretend'] > 0
    FileUtils.mv(original, destination)
  end

  def self.file_rm(files)
    if $env_flags['pretend'] > 0
      $speaker.speak_up("Would rm #{files}") if files.is_a?(Array) || files.to_s != ''
    else
      FileUtils.rm(files) if files.is_a?(Array) || files.to_s != ''
    end
    file_remove_parents(files)
  end

  def self.file_rm_r(files)
    if $env_flags['pretend'] > 0
      $speaker.speak_up("Would rm_r #{files}")
    else
        FileUtils.rm_r(files)
    end
    file_remove_parents(files)
  end

  def self.file_rmdir(dirs)
    if $env_flags['pretend'] > 0
      $speaker.speak_up("Would rmdir #{dirs}")
    else
      FileUtils.rmdir(dirs)
    end
    file_remove_parents(dirs)
  end

  def self.file_ln(original, destination)
    return $speaker.speak_up("Would ln #{original} to #{destination}") if $env_flags['pretend'] > 0
    FileUtils.ln(original, destination)
  end

  def self.get_disk_size(path)
    size=0
    Find.find(path) { |file| size+= File.size(file) }
    size
  end

  def self.get_disk_space(path)
    stat = Sys::Filesystem.stat(path)
    return stat.block_size * stat.blocks_available, stat.blocks * stat.block_size
  end

  def self.get_only_folder_levels(path, level = 1)
    cpt = 0
    initial_f = path
    f = File.basename(path)
    while cpt <= level
      break if path == File.dirname(path)
      path = File.dirname(path)
      f = File.basename(path) + '/' + f
      cpt += 1
    end
    return f.gsub(/^\.\//,''), initial_f.gsub(f, '')
  end

  def self.get_path_depth(path, folder)
    folder = folder + '/' unless folder[-1] == '/'
    parent = File.dirname(path.gsub(folder, ''))
    if parent == '.'
      1
    else
      1 + get_path_depth(File.dirname(path), folder)
    end
  end

  def self.get_pid(process)
    `ps ax | grep #{process} | grep -v grep | cut -f1 -d' '`.gsub(/\n/, '')
  end

  def self.get_top_folder(path)
    return path.gsub(/^\/?([^\/]*)\/.*/, '\1').to_s, path.gsub(/^\/?([^\/]*)\//, '').to_s
  end

  def self.get_traffic(network_card)
    in_t, out_t, in_s, out_s = nil, nil, 0, 0
    (1..2).each do |i|
      _in_t, _out_t = in_t, out_t
      in_t = `cat /proc/net/dev | grep #{network_card} | cut -f2 -d':' | tail -n'+1' | awk '{print $1}'`.gsub(/\n/, '').to_i
      out_t = `cat /proc/net/dev | grep #{network_card} | cut -f2 -d':' | tail -n'+1' | awk '{print $9}'`.gsub(/\n/, '').to_i
      if i == 2
        in_s = (in_t - _in_t)
        out_s = (out_t - _out_t)
      else
        sleep 1
      end
    end
    return in_s/1024, out_s/1024
  end

  def self.is_in_path(path_list, folder)
    path_list.each do |p|
      return p if folder.gsub('//', '/').include?(p.gsub('//', '/')) || p.gsub('//', '/').include?(folder.gsub('//', '/'))
    end
    return nil
  end

  def self.md5sum(file)
    md5 = File.open(file, 'rb') do |io|
      dig = Digest::MD5.new
      buf = ""
      dig.update(buf) while io.read(4096, buf)
      dig
    end
    md5.to_s
  end

  def self.move_file(original, destination, hard_link = 0, remove_outdated = 0)
    destination = destination.gsub(/\.\.+/, '.').gsub(/[\'\"\;\:]/, '')
    if File.exists?(destination)
      _, prosper = MediaInfo.identify_proper(original)
      if remove_outdated.to_i > 0 && prosper.to_i > 0
        $speaker.speak_up("File #{File.basename(original)} is an upgrade release, replacing existing file #{File.basename(destination)}.")
        file_rm(destination)
      else
        $speaker.speak_up("File #{File.basename(destination)} is correctly named, skipping...", 0)
        return false, destination
      end
    end
    $speaker.speak_up("#{hard_link.to_i > 0 ? 'Linking' : 'Moving'} '#{original}' to '#{destination}'")
    Utils.file_mkdir_p(File.dirname(destination)) unless Dir.exist?(File.dirname(destination))
    if hard_link.to_i > 0
      file_ln(original, destination)
    else
      file_mv(original, destination)
    end
    return true, destination
  rescue => e
    $speaker.tell_error(e, 'utils.move_file')
    return false, ''
  end

  def self.parse_filename_template(tpl, metadata)
    return nil if metadata.nil?
    FILENAME_NAMING_TEMPLATE.each do |k|
      tpl = tpl.gsub(Regexp.new('\{\{ ' + k + '((\|[a-z]*)+)? \}\}')) { Utils.regularise_media_filename(metadata[k], $1) }
    end
    tpl
  end

  def self.object_pack(object)
    if object.is_a?(Array)
      object.each_with_index { |o, idx| object[idx] = object_pack(o.clone) }
    else
      packed = object_to_hash(object)
      packed = object.to_s if packed.empty?
      object = [object.class.to_s, packed]
    end
    object
  end

  def self.object_to_hash(object)
    object.instance_variables.each_with_object({}) { |var, hash| hash[var.to_s.delete("@")] = object.instance_variable_get(var).to_s }
  end

  def self.object_unpack(object)
    object = eval(object) rescue object
    return object unless object.is_a?(Array)
    if object.count == 2 && object[0].is_a?(String) && !object[1].is_a?(Array)
      o = Object.const_get(object[0]).new(object[1]) rescue object[1]
      object = object[0] == 'Hash' ? object[1] : o
    else
      object.each_with_index { |o, idx| object[idx] = object_unpack(o) }
    end
    object
  end

  def self.recursive_symbolize_keys(h)
    case h
      when Hash
        Hash[
            h.map do |k, v|
              [k.respond_to?(:to_sym) ? k.to_sym : k, recursive_symbolize_keys(v)]
            end
        ]
      when Enumerable
        h.map { |v| recursive_symbolize_keys(v) }
      else
        h
    end
  end

  def self.regexify(str, strict = 1)
    if strict.to_i <= 0
      str.strip.gsub(/[:,-\/\[\]]/, '.*').gsub(/ /, '.*').gsub("'", "'?")
    else
      str.strip.gsub(/[:,-\/\[\]]/, '.{0,2}').gsub(/ /, '.').gsub("'", "'?")
    end
  end

  def self.regularise_media_filename(filename, formatting = '')
    r = filename.to_s.gsub(/[\'\"\;\:\,]/, '').gsub(/\//,' ')
    r = r.downcase.titleize if formatting.to_s.gsub(/[\(\)]/, '').match(/.*titleize.*/)
    r = r.downcase if formatting.to_s.match(/.*downcase.*/)
    r = r.gsub(/[\ \(\)]/, '.') if formatting.to_s.match(/.*nospace.*/)
    r
  end

  def self.regularise_media_type(type)
    return type + 's' if VALID_VIDEO_MEDIA_TYPE.include?(type + 's')
    type
  rescue
    type
  end

  def self.search_folder(folder, filter_criteria = {})
    filter_criteria = {} if filter_criteria.nil?
    search_folder = []
    Find.find(folder).each do |path|
      next if path == folder
      parent = File.basename(File.dirname(path))
      next if File.basename(path).start_with?('.')
      next if parent.start_with?('.')
      next unless File.exist?(path)
      depth = get_path_depth(path, folder)
      breakflag = 0
      breakflag = 1 if breakflag == 0 && FileTest.directory?(path) && !filter_criteria['includedir'] && !filter_criteria['dironly']
      breakflag = 1 if breakflag == 0 && !FileTest.directory?(path) && filter_criteria['dironly']
      breakflag = 1 if breakflag == 0 && filter_criteria['name'] && !File.basename(path).downcase.include?(filter_criteria['name'].downcase)
      breakflag = 1 if breakflag == 0 && filter_criteria['regex'] && !File.basename(path).downcase.match(filter_criteria['regex'].downcase) && !parent.match(filter_criteria['regex'])
      breakflag = 1 if breakflag == 0 && filter_criteria['exclude'] && File.basename(path).include?(filter_criteria['exclude'])
      breakflag = 1 if breakflag == 0 && filter_criteria['exclude_strict'] && File.basename(path) == filter_criteria['exclude_strict']
      breakflag = 1 if breakflag == 0 && filter_criteria['exclude_strict'] && parent == filter_criteria['exclude_strict']
      breakflag = 1 if breakflag == 0 && filter_criteria['days_older'].to_i > 0 && File.mtime(path) > Time.now - filter_criteria['days_older'].to_i.days
      breakflag = 1 if breakflag == 0 && filter_criteria['days_newer'].to_i > 0 && File.mtime(path) < Time.now - filter_criteria['days_newer'].to_i.days
      breakflag = 1 if breakflag == 0 && (filter_criteria['exclude_path'] && filter_criteria['exclude_path'].is_a?(Array) && is_in_path(filter_criteria['exclude_path'], path)) || path.include?('@eaDir')
      breakflag = 1 if breakflag == 0 && filter_criteria['str_closeness'].to_i > 0 && filter_criteria['str_closeness_comp'] &&
          $str_closeness.getDistance(File.basename(path), filter_criteria['str_closeness_comp']) < filter_criteria['str_closeness'].to_i &&
          $str_closeness.getDistance(parent, filter_criteria['str_closeness_comp']) < filter_criteria['str_closeness'].to_i
      search_folder << [File.absolute_path(path), parent] if breakflag == 0
      if filter_criteria['maxdepth'].to_i > 0 && depth >= filter_criteria['maxdepth'].to_i
        Find.prune if FileTest.directory?(path)
      end
      next if breakflag > 0
      break if filter_criteria['return_first']
    end
    search_folder
  rescue => e
    $speaker.tell_error(e, "Library.search_folder")
    []
  end

  def self.timeperiod_to_sec(argument)
    return argument if argument.class < Integer
    if argument.class == String
      case argument
        when /^(.*?)[+,](.*)$/                     then to_sec($1) + to_sec($2)
        when /^\s*([0-9_]+)\s*\*(.+)$/             then $1.to_i * to_sec($2)
        when /^\s*[0-9_]+\s*(s(ec(ond)?s?)?)?\s*$/ then argument.to_i
        when /^\s*([0-9_]+)\s*m(in(ute)?s?)?\s*$/  then $1.to_i *      60
        when /^\s*([0-9_]+)\s*h(ours?)?\s*$/       then $1.to_i *    3600
        when /^\s*([0-9_]+)\s*d(ays?)?\s*$/        then $1.to_i *   86400
        when /^\s*([0-9_]+)\s*w(eeks?)?\s*$/       then $1.to_i *  604800
        when /^\s*([0-9_]+)\s*months?\s*$/         then $1.to_i * 2419200
        else                                            0
      end
    end
  end

  def self.title_match_string(str)
    '^([Tt]he )?' + regexify(str.gsub(/(\w*)\(\d+\)/, '\1').gsub(/^[Tt]he /, '').gsub(/([Tt]he)?.T[Vv].[Ss]eries/, '').gsub(/ \(US\)$/, '')) + '.{0,7}$'
  end

end
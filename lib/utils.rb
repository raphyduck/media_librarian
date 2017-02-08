class Utils
  include Sys

  def self.check_if_inactive(active_hours)
    active_hours && active_hours.is_a?(Array) && active_hours.count >= 2 && (Time.now.utc.hour < active_hours[0].to_i || Time.now.utc.hour > active_hours[1].to_i)
  end

  def self.get_disk_size(path)
    size=0
    Find.find(path) { |file| size+= File.size(file)}
    size
  end

  def self.get_disk_space(path)
    stat = Sys::Filesystem.stat(path)
    return stat.block_size * stat.blocks_available, stat.blocks * stat.block_size
  end

  def self.get_path_depth(path, folder)
    folder = folder + '/' unless folder[-1] == '/'
    parent = File.dirname(path.gsub(folder,''))
    if parent == '.'
      1
    else
      1 + get_path_depth(File.dirname(path), folder)
    end
  end

  def self.is_in_path(path_list, folder)
    path_list.each do |p|
      return true if folder.gsub('//','/').include?(p.gsub('//','/')) || p.gsub('//','/').include?(folder.gsub('//','/'))
    end
    return false
  end

  def self.load_template(template_name)
    if template_name.to_s != '' && File.exist?($template_dir + '/' + "#{template_name}.yml")
      return YAML.load_file($template_dir + '/' + "#{template_name}.yml")
    end
    {}
  rescue => e
    Speaker.tell_error(e, "Utils.load_template")
    {}
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

  def self.recursive_symbolize_keys(h)
    case h
      when Hash
        Hash[
            h.map do |k, v|
              [ k.respond_to?(:to_sym) ? k.to_sym : k, recursive_symbolize_keys(v) ]
            end
        ]
      when Enumerable
        h.map { |v| recursive_symbolize_keys(v) }
      else
        h
    end
  end

  def self.regexify(str)
    str.strip.gsub(/[:,-\/\[\]]/,'.{0,2}').gsub(/ /,'.').gsub("'","'?")
  end

  def self.search_folder(folder, filter_criteria = {})
    filter_criteria = eval(filter_criteria) if filter_criteria.is_a?(String)
    filter_criteria = {} if filter_criteria.nil?
    search_folder = []
    Find.find(folder).each do |path|
      next if path == folder
      parent = File.basename(File.dirname(path))
      next if File.basename(path).start_with?('.')
      next if parent.start_with?('.')
      depth = get_path_depth(path, folder)
      breakflag = 0
      breakflag = 1 if breakflag == 0 && FileTest.directory?(path) && !filter_criteria['includedir']
      breakflag = 1 if breakflag == 0 && filter_criteria['name'] && !File.basename(path).downcase.include?(filter_criteria['name'].downcase)
      breakflag = 1 if breakflag == 0 && filter_criteria['regex'] && !File.basename(path).downcase.match(filter_criteria['regex'].downcase) && !parent.match(filter_criteria['regex'])
      breakflag = 1 if breakflag == 0 && filter_criteria['exclude'] && File.basename(path).include?(filter_criteria['exclude'])
      breakflag = 1 if breakflag == 0 && (filter_criteria['exclude_path'] && path.include?(filter_criteria['exclude_path'])) || path.include?('@eaDir')
      breakflag = 1 if breakflag == 0 && filter_criteria['exclude_strict'] && File.basename(path) == filter_criteria['exclude_strict']
      breakflag = 1 if breakflag == 0 && filter_criteria['exclude_strict'] && parent == filter_criteria['exclude_strict']
      breakflag = 1 if breakflag == 0 && filter_criteria['days_older'].to_i > 0 && File.ctime(path) > Time.now - filter_criteria['days_older'].to_i.days
      breakflag = 1 if breakflag == 0 && filter_criteria['days_newer'].to_i > 0 && File.mtime(path) < Time.now - filter_criteria['days_newer'].to_i.days
      breakflag = 1 if breakflag == 0 && filter_criteria['str_closeness'].to_i > 0 && filter_criteria['str_closeness_comp'] &&
          $str_closeness.getDistance(File.basename(path), filter_criteria['str_closeness_comp']) < filter_criteria['str_closeness'].to_i &&
          $str_closeness.getDistance(parent, filter_criteria['str_closeness_comp']) < filter_criteria['str_closeness'].to_i
      search_folder << [path, parent] if breakflag == 0
      if filter_criteria['maxdepth'].to_i > 0 && depth >= filter_criteria['maxdepth'].to_i
        Find.prune if FileTest.directory?(path)
      end
      next if breakflag > 0
      break if filter_criteria['return_first']
    end
    search_folder
  rescue => e
    Speaker.tell_error(e, "Library.search_folder")
    []
  end

  def self.title_match_string(str)
    '^([Tt]he )?' + regexify(str.gsub(/(\w*)\(\d+\)/, '\1').gsub(/^[Tt]he /, '').gsub(/([Tt]he)?.T[Vv].[Ss]eries/,'').gsub(/ \(US\)$/,'')) + '.{0,7}$'
  end
end
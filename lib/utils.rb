require File.dirname(__FILE__) + '/string_utils'
class Utils

  @mutex = {}
  @lock = Mutex.new

  def self.bash(command)
    escaped_command = Shellwords.escape(command)
    system "bash -c #{escaped_command}"
  end

  def self.check_if_active(active_hours = {})
    !active_hours.is_a?(Hash) ||
        ((active_hours['start'].nil? || active_hours['start'].to_i <= Time.now.hour) &&
            (active_hours['end'].nil? || active_hours['end'].to_i >= Time.now.hour) &&
            (active_hours['start'].nil? || active_hours['end'].nil? || active_hours['start'].to_i <= active_hours['end'])) ||
        (active_hours['start'].to_i > active_hours['end'].to_i && (active_hours['start'].to_i <= Time.now.hour ||
            active_hours['end'].to_i >= Time.now.hour))
  end

  def self.arguments_dump(binding, max_depth = 2)
    class_name = caller[0].match(/\/(\w*)\.rb:/)[1].gsub('_', ' ').titleize.gsub(' ', '')
    calling_name = caller[0][/`.*'/][1..-2].gsub('rescue in ', '')
    hash_params = Hash[arguments_get(binding, class_name, calling_name, 0, max_depth)]
    "#{class_name}.#{calling_name}(#{hash_params})"
  end

  def self.arguments_get(binding, cname, mname, ptype = 0, max_depth = 1)
    params = Object.const_get(cname).method(mname).parameters rescue nil
    params = Object.const_get(cname).instance_method(mname).parameters unless params && params != [[:rest]]
    params.map.collect do |k, name|
      next if (k[0..2] == 'key' && ptype.to_i == 1) || (ptype.to_i == 2 && k[0..2] != 'key')
      [name, DataUtils.dump_variable(binding.local_variable_get(name), max_depth, 0, 0).to_s]
    end.compact
  rescue
    [[:error, "error fetching arguments from cname='#{cname}', mname='#{mname}', ptype='#{ptype}'"]]
  end

  def self.forget(table:, entry:)
    column = $db.get_main_column(table)
    $db.delete_rows(table, {column => entry.to_s}) if column
  end

  def self.get_pid(process)
    `ps ax | grep #{process} | grep -v grep | cut -f1 -d' '`.gsub(/\n/, '')
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
    return in_s / 1024, out_s / 1024
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    return nil, nil
  end

  def self.list_db(table:, entry: '')
    return [] unless DB_SCHEMA.map {|k, _| k.to_s}.include?(table)
    column = $db.get_main_column(table)
    r = if entry.to_s == ''
          $db.get_rows(table)
        else
          $db.get_rows(table, {column => entry.to_s})
        end
    r.each {|row| $speaker.speak_up row.to_s}
  end

  def self.lock_block(process_name, &block)
    process_name.gsub!(/[\{\}\(\)]/, '')
    start = Time.now
    @lock.synchronize {
      @mutex[process_name] = Mutex.new if @mutex[process_name].nil?
    }
    r = @mutex[process_name].synchronize &block
    lock_timer_register(process_name, Time.now - start)
    r
  end

  def self.lock_time_get(thread = Thread.current)
    lt = ' including '
    (thread[:lock_time] || {}).sort_by {|_, t| -t}.each do |p, t|
      lt += "#{TimeUtils.seconds_in_words(t)} locked for '#{p}', " if t >= 0.001
    end
    return '' if lt == ' including '
    lt
  end

  def self.lock_time_merge(from, to = Thread.current)
    return if from[:lock_time].nil?
    from[:lock_time].each do |p, t|
      lock_timer_register(p, t, to)
    end
  end

  def self.lock_timer_register(process_name, value, thread = Thread.current)
    thread[:lock_time] = {} unless thread[:lock_time]
    thread[:lock_time].keys.each do |k|
      next if k == process_name
      i = StringUtils.intersection(k, process_name)
      if i.length > 2 && i[0] == process_name[0]
        process_name = "#{i}*"
        if process_name != k
          value += thread[:lock_time][k]
          thread[:lock_time].delete(k)
        end
      end
    end
    thread[:lock_time][process_name] = 0 unless thread[:lock_time][process_name]
    thread[:lock_time][process_name] += value
  end

  def self.match_release_year(year, target_year)
    year == 0 || (year <= target_year + 1 && year >= target_year - 1) #|| target_year == 0
  end

  def self.parse_filename_template(tpl, metadata)
    return nil if metadata.nil?
    FILENAME_NAMING_TEMPLATE.each do |k|
      tpl = tpl.gsub(Regexp.new('\{\{ ' + k + '((\|[a-z]*)+)? \}\}')) {StringUtils.regularise_media_filename(recursive_typify_keys(metadata)[k.to_sym], $1)}
    end
    tpl
  end

  def self.recursive_typify_keys(h, symbolize = 1)
    typify = symbolize.to_i > 0 ? 'to_sym' : 'to_s'
    case h
    when Hash
      Hash[
          h.map do |k, v|
            [k.respond_to?(typify) ? k.public_send(typify) : k, recursive_typify_keys(v, symbolize)]
          end
      ]
    when Enumerable
      h.map {|v| recursive_typify_keys(v, symbolize)}
    else
      h
    end
  end

  def self.regularise_media_type(type)
    return type + 's' if VALID_VIDEO_MEDIA_TYPE.include?(type + 's')
    type
  rescue
    type
  end

  def self.timeperiod_to_sec(argument)
    return argument if argument.class < Integer
    if argument.class == String
      case argument
      when /^(.*?)[+,](.*)$/ then
        timeperiod_to_sec($1) + timeperiod_to_sec($2)
      when /^\s*([0-9_]+)\s*\*(.+)$/ then
        $1.to_i * timeperiod_to_sec($2)
      when /^\s*[0-9_]+\s*(s(ec(ond)?s?)?)?\s*$/ then
        argument.to_i
      when /^\s*([0-9_]+)\s*m(in(ute)?s?)?\s*$/ then
        $1.to_i * 60
      when /^\s*([0-9_]+)\s*h(ours?)?\s*$/ then
        $1.to_i * 3600
      when /^\s*([0-9_]+)\s*d(ays?)?\s*$/ then
        $1.to_i * 86400
      when /^\s*([0-9_]+)\s*w(eeks?)?\s*$/ then
        $1.to_i * 604800
      when /^\s*([0-9_]+)\s*months?\s*$/ then
        $1.to_i * 2419200
      else
        0
      end
    end
  end

end
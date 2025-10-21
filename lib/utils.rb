require File.dirname(__FILE__) + '/string_utils'
class Utils

  @mutex = {}
  @lock = Mutex.new

  def self.bash(command)
    system('bash', '-c', command)
  end

  def self.check_if_active(active_hours = {})
    !active_hours.is_a?(Hash) ||
        ((active_hours['start'].nil? || active_hours['start'].to_i <= Time.now.hour) &&
            (active_hours['end'].nil? || active_hours['end'].to_i >= Time.now.hour) &&
            (active_hours['start'].nil? || active_hours['end'].nil? || active_hours['start'].to_i <= active_hours['end'])) ||
        (active_hours['start'].to_i > active_hours['end'].to_i && (active_hours['start'].to_i <= Time.now.hour ||
            active_hours['end'].to_i >= Time.now.hour))
  end

  def self.arguments_dump(binding, max_depth = 2, class_name = '', calling_name = '')
    caller_info = caller(1..1).first
    if caller_info
      if class_name.to_s == ''
        class_match = caller_info.match(/\/(\w*)\.rb:/)
        class_name = class_match[1].gsub('_', ' ').titleize.gsub(' ', '') if class_match
      end
      if calling_name.to_s == ''
        method_match = caller_info[/`.*'/]
        calling_name = method_match[1..-2].gsub('rescue in ', '') if method_match
      end
    end

    class_name = class_name.to_s
    calling_name = calling_name.to_s
    args_params, hash_params = arguments_get(binding, class_name, calling_name, max_depth)
    "#{class_name}.#{calling_name}(#{args_params.map { |_, v| v }.join(', ') unless args_params.nil? || args_params.empty?}#{', ' unless args_params.nil? || args_params.empty? || hash_params.nil? || hash_params.empty?}#{Hash[hash_params] unless hash_params.nil? || hash_params.empty?})"
  end

  def self.arguments_get(binding, cname, mname, max_depth = 1)
    params = Object.const_get(cname).method(mname).parameters rescue nil
    params = Object.const_get(cname).method(ExecutionHooks.alias_hook(mname)).parameters unless params.nil? || params != [[:rest, :args]]
    params = Object.const_get(cname).instance_method(mname).parameters unless params && params != [[:rest]]
    regs, hashs = [], []
    i = -1
    params.each do |k, name|
      i += 1
      v = if binding.is_a?(Binding)
            binding.local_variable_get(name)
          elsif binding.is_a?(Array)
            binding[i]
          elsif binding.is_a?(Hash)
            binding[name]
          end
      if k[0..2] == 'key'
        hashs << [name, DataUtils.dump_variable(v, max_depth, 0, 0).to_s]
      else
        regs << [name, DataUtils.dump_variable(v, max_depth, 0, 0).to_s]
      end
    end
    return regs.compact, hashs.compact
  rescue
    return nil, [[:error, "error fetching arguments from cname='#{cname}', mname='#{mname}'"]]
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
    MediaLibrarian.app.speaker.tell_error(e, Utils.arguments_dump(binding))
    return nil, nil
  end

  def self.list_db(table:, entry: '')
    return [] unless MediaLibrarian.app.db.table_exists?(table)
    column = MediaLibrarian.app.db.get_main_column(table)
    r = if entry.to_s == ''
          MediaLibrarian.app.db.get_rows(table)
        else
          MediaLibrarian.app.db.get_rows(table, {column => entry.to_s})
        end
    r.each { |row| MediaLibrarian.app.speaker.speak_up row.to_s }
  end

  def self.lock_block(process_name, nonex = 0, &block)
    process_name.gsub!(/[\{\}\(\)]/, '')
    lock_name = "lock_#{process_name}_on"
    if Thread.current[lock_name] == 1
      r = block.call
    else
      start = Time.now
      @lock.synchronize {
        @mutex[process_name] = Mutex.new if @mutex[process_name].nil?
      }
      Thread.current[:locked_by] = process_name
      Thread.current[:nonex_lock] = nonex
      @mutex[process_name].synchronize do
        Thread.current[lock_name] = 1
        Thread.current[:locked_by] = nil
        Thread.current[:nonex_lock] = nil
        r = block.call
        Thread.current[lock_name] = nil
        Thread.current[:locked_by] = process_name
        Thread.current[:nonex_lock] = nonex
      end
      Thread.current[:locked_by] = nil
      Thread.current[:nonex_lock] = nil
      lock_timer_register(process_name, Time.now - start)
    end
    r
  end

  def self.lock_time_get(thread = Thread.current)
    lt = ' including '
    (thread[:lock_time] || {}).sort_by { |_, t| -t }.each do |p, t|
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

  def self.match_release_year(target_year, year)
    target_year.to_i == 0 || (target_year.to_i - Time.now.year).abs >= 100 || (year.to_i - Time.now.year).abs >= 100 || (year.to_i <= target_year.to_i + 1 && year.to_i >= target_year.to_i - 1) #|| year == 0
  end

  def self.parse_filename_template(tpl, metadata)
    FILENAME_NAMING_TEMPLATE.each do |k|
      tpl = tpl.gsub(Regexp.new('\{\{ ' + k + '((\|[a-z]*)+)? \}\}')) { StringUtils.regularise_media_filename(recursive_typify_keys(metadata || {})[k.to_sym], $1) }
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
      h.map { |v| recursive_typify_keys(v, symbolize) }
    else
      h
    end
  end

  def self.recursive_stringify_values(h)
    case h
    when Hash
      Hash[h.map { |k, v| [k, recursive_stringify_values(v)] }]
    else
      h.to_s
    end
  end

  def self.regularise_media_type(type)
    return type + 's' if VALID_MEDIA_TYPES.map { |_, v| v }.flatten.include?(type + 's')
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
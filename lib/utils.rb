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
    return in_s/1024, out_s/1024
  rescue => e
    $speaker.tell_error(e, "Utils.get_traffic(#{network_card})")
    return nil, nil
  end

  def self.list_db(table:, entry: '')
    return [] unless DB_SCHEMA.map { |k, _| k.to_s }.include?(table)
    column = $db.get_main_column(table)
    r = if entry.to_s == ''
          $db.get_rows(table)
        else
          $db.get_rows(table, {column => entry.to_s})
        end
    r.each { |row| $speaker.speak_up row.to_s }
  end

  def self.lock_block(process_name, &block)
    @lock.synchronize {
      @mutex[process_name] = Mutex.new if @mutex[process_name].nil?
    }
    @mutex[process_name].synchronize &block
  end

  def self.parse_filename_template(tpl, metadata)
    return nil if metadata.nil?
    FILENAME_NAMING_TEMPLATE.each do |k|
      tpl = tpl.gsub(Regexp.new('\{\{ ' + k + '((\|[a-z]*)+)? \}\}')) { StringUtils.regularise_media_filename(recursive_typify_keys(metadata)[k.to_sym], $1) }
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
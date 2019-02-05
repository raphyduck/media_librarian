require File.dirname(__FILE__) + '/vash'
require File.dirname(__FILE__) + '/bus_variable'
class Cache
  @tqueues = {}
  @cache_metadata = BusVariable.new('cache_metadata', Vash)

  def self.cache_add(type, keyword, result, full_save = nil)
    if keyword.to_s == ''
      $speaker.speak_up("Empty keyword, not saving cache") if Env.debug?
      return
    end
    $speaker.speak_up "Refreshing #{type} cache for #{keyword}#{' will not be saved to db' if full_save.nil?}" if Env.debug?
    @cache_metadata[type.to_s + keyword.to_s, CACHING_TTL] = result.clone
    r = object_pack(result)
    $db.insert_row('metadata_search', {
        :keywords => keyword,
        :type => cache_get_enum(type),
        :result => r,
    }, 0) if cache_get_enum(type) && full_save && r
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    raise e
  end

  def self.cache_expire(row)
    $db.delete_rows('metadata_search', row)
  end

  def self.cache_get(type, keyword, expiration = 120)
    return nil unless cache_get_enum(type)
    return @cache_metadata[type.to_s + keyword.to_s] if @cache_metadata[type.to_s + keyword.to_s]
    res = $db.get_rows('metadata_search', {:type => cache_get_enum(type), :keywords => keyword})
    res.each do |r|
      if Time.parse(r[:created_at]) < Time.now - expiration.days && !Env.pretend?
        cache_expire(r)
        next
      end
      result = object_unpack(r[:result])
      @cache_metadata[type.to_s + keyword.to_s, CACHING_TTL] = result
      return result
    end
    nil
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    $speaker.speak_up "An error occured loading cache for type '#{type}' and keyword '#{keyword}', removing entry"
    $db.delete_rows('metadata_search', {:type => cache_get_enum(type), :keywords => keyword})
    nil
  end

  def self.cache_get_enum(type)
    METADATA_SEARCH[:type_enum][type.to_sym] rescue nil
  end

  def self.cache_get_mediatype_enum(type)
    METADATA_SEARCH[:media_type][type.to_sym][:enum] rescue nil
  end

  def self.cache_reset(type:)
    return nil unless cache_get_enum(type)
    $db.delete_rows('metadata_search', {:type => cache_get_enum(type)})
    @cache_metadata.delete_if {|c, _| c.start_with?(type)}
  end

  def self.object_pack(object, to_hash_only = 0)
    obj = object.is_a?(Thread) ? object : object.clone
    oclass = obj.class.to_s
    if [String, Integer, Float, BigDecimal, NilClass, TrueClass, FalseClass].include?(obj.class)
      obj = obj.to_s
    elsif [Date, DateTime, Time].include?(obj.class)
      obj = obj.strftime('%Y-%m-%dT%H:%M:%S%z')
    elsif obj.is_a?(Array)
      obj.each_with_index {|o, idx| obj[idx] = object_pack(o, to_hash_only)}
    elsif obj.is_a?(Hash)
      obj.keys.each {|k| obj[k] = object_pack(obj[k], to_hash_only)}
    elsif obj.is_a?(Thread)
      obj = "thread[#{Hash[obj.keys.map do |k|
        [k, to_hash_only.to_i == 1 && obj[k].respond_to?("[]") ? obj[k][0..100] : obj[k]] rescue nil
      end]}]"
    else
      obj = object.instance_variables.each_with_object({}) {|var, hash| hash[var.to_s.delete("@")] = object_pack(object.instance_variable_get(var), to_hash_only)}
    end
    obj = [oclass, obj] if to_hash_only.to_i == 0
    obj
  end

  def self.object_unpack(object)
    object = begin
      object.is_a?(String) && object.match(/^[{\[].*[}\]]$/) ? eval(object.clone) : object.clone
    rescue Exception
      object.clone
    end
    return object unless object.is_a?(Array) || object.is_a?(Hash)
    #TODO: Fix retore "Class" metadata
    if object.is_a?(Array) && object.count == 2 && object[0].is_a?(String) && (Object.const_defined?(object[0]) rescue false)
      if object[0] == 'Hash'
        object = begin
          eval(object[1])
        rescue Exception
          object[1]
        end
        object.keys.each {|k| object[k] = object_unpack(object[k])}
      elsif Object.const_get(object[0]).respond_to?('strptime')
        object = begin
          Object.const_get(object[0]).strptime(object_unpack(object[1]), '%Y-%m-%dT%H:%M:%S%z')
        rescue
          Object.const_get(object[0]).strptime(object_unpack(object[1]), '%Y-%m-%d %H:%M:%S %z')
        end
      elsif Object.const_get(object[0]).respond_to?('new')
        object = Object.const_get(object[0]).new(object_unpack(object[1]))
      else
        object = object_unpack(object[1])
      end
    elsif object.is_a?(Array)
      object.each_with_index {|o, idx| object[idx] = object_unpack(o)}
    else
      object.keys.each {|k| object[k] = object_unpack(object[k])}
    end
    object
  end

  def self.queue_state_add_or_update(qname, el, unique = 1)
    $speaker.speak_up "Will add element '#{el}' to queue '#{qname}'" if Env.debug?
    el = [el] unless el.is_a?(Hash) || el.is_a?(Array)
    h = queue_state_get(qname, el.is_a?(Hash) ? Hash : Array)
    return if unique.to_i > 0 && h.is_a?(Array) && h.include?(el[0])
    h = (el + h rescue el)
    queue_state_save(qname, h)
  end

  def self.queue_state_get(qname, type = Hash)
    return @tqueues[qname] if @tqueues[qname]
    res = $db.get_rows('queues_state', {:queue_name => qname}).first
    @tqueues[qname] = object_unpack(res[:value]) rescue type.new
    @tqueues[qname]
  end

  def self.queue_state_remove(qname, key)
    $speaker.speak_up "Will remove key '#{key}' from queue '#{qname}'" if Env.debug?
    h = queue_state_get(qname)
    h.delete(key)
    queue_state_save(qname, h)
  end

  def self.queue_state_save(qname, value)
    Utils.lock_block("#{__method__}_#{qname}") {
      @tqueues[qname] = value
      return @tqueues[qname] if Env.pretend?
      r = object_pack(value)
      $db.insert_row('queues_state', {
          :queue_name => qname,
          :value => r,
      }, 1) if r
    }
    @tqueues[qname]
  end

  def self.queue_state_select(qname, save = 0, &block)
    h = queue_state_get(qname)
    return h.select {|k, v| block.call(k, v)} if save == 0
    queue_state_save(qname, h.select {|k, v| block.call(k, v)})
  end

  def self.queue_state_shift(qname)
    $speaker.speak_up "Will shift from queue '#{qname}'" if Env.debug?
    h = queue_state_get(qname)
    el = h.shift
    queue_state_save(qname, h)
    el
  rescue
    nil
  end

  def self.torrent_deja_vu?(identifier, qualities, f_type)
    return false if identifier[0..3] == 'book' #TODO: Find a more elegant way of handling this
    torrent_get(identifier, f_type).each do |t|
      next unless t[:in_db].to_i > 0 && t[:download_now].to_i >= 3
      timeframe, accept = MediaInfo.filter_quality(t[:name], qualities)
      if timeframe.to_s == '' && accept
        $speaker.speak_up "Torrent for identifier '#{identifier}' already existing at correct quality (#{qualities})" if Env.debug?
        return true
      end
    end
    $speaker.speak_up "No downloaded torrent found for identifier '#{identifier}' at quality (#{qualities})" if Env.debug?
    false
  end

  def self.torrent_get(identifier, f_type = nil)
    torrents = []
    $db.get_rows('torrents', {}, {'identifier like' => "%#{identifier}%"}).each do |d|
      d[:tattributes] = Cache.object_unpack(d[:tattributes])
      if Time.parse(d[:waiting_until]) < Time.now - 180.days && d[:status].to_i <= 2 && d[:status].to_i >= 0
        $speaker.speak_up "Removing stalled torrent '#{d[:name]}' (id '#{d[:identifier]}')" if Env.debug?
        $db.delete_rows('torrents', {:name => d[:name], :identifier => d[:identifier]})
        next
      end
      next unless (f_type.nil? || d[:tattributes][:f_type].nil? || d[:tattributes][:f_type].to_s == f_type.to_s)
      t = -1
      if Time.parse(d[:waiting_until]) > Time.now && d[:status].to_i >= 0 && d[:status].to_i < 2
        $speaker.speak_up("Timeframe set for '#{d[:name]}' on #{d[:created_at]}, waiting until #{d[:waiting_until]}", 0)
        t = 1
      elsif d[:status].to_i >= 0 && d[:status].to_i < 2
        t = 2
      elsif d[:status].to_i > 2
        t = 3
      elsif Env.debug?
        $speaker.speak_up("Torrent '#{d[:name]}' corrupted, skipping")
      end
      torrents << d[:tattributes].merge({:download_now => t, :in_db => 1})
    end
    torrents
  end
end
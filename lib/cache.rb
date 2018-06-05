require File.dirname(__FILE__) + '/vash'
class Cache
  @tqueues = {}
  @cache_metadata = Vash.new

  def self.cache_add(type, keyword, result, full_save = nil)
    $speaker.speak_up "Refreshing #{type} cache for #{keyword}#{' will not be saved to db' if full_save.nil?}" if Env.debug?
    @cache_metadata[type.to_s + keyword.to_s, CACHING_TTL] = result.clone
    r = object_pack(result)
    $db.insert_row('metadata_search', {
        :keywords => keyword,
        :type => cache_get_enum(type),
        :result => r,
    }) if cache_get_enum(type) && full_save && r
  end

  def self.cache_expire(row)
    $db.delete_rows('metadata_search', row)
  end

  def self.cache_get(type, keyword, expiration = 120)
    return nil unless cache_get_enum(type)
    return @cache_metadata[type.to_s + keyword.to_s] if @cache_metadata[type.to_s + keyword.to_s]
    res = $db.get_rows('metadata_search', {:type => cache_get_enum(type),
                                           :keywords => keyword}
    )
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
  end

  def self.cache_get_enum(type)
    METADATA_SEARCH[:type_enum][type.to_sym] rescue nil
  end

  def self.cache_get_mediatype_enum(type)
    METADATA_SEARCH[:media_type][type.to_sym][:enum] rescue nil
  end

  def self.entry_deja_vu?(category, entry, expiration = 180)
    entry = [entry] unless entry.is_a?(Array)
    dejavu = false
    entry.each do |e|
      a = $db.get_rows('seen', {:category => 'global'}, {'entry like' => "%#{e.downcase.gsub(' ', '')}%"})
      a = $db.get_rows('seen', {:category => category}, {'entry like' => "%#{e.downcase.gsub(' ', '')}%"}) if a.empty?
      a.delete_if do |r|
        created = Time.parse(r[:created_at])
        $db.delete_rows('seen',{:entry => r[:entry]}) if created < Time.now - expiration.days
        created < Time.now - expiration.days
      end
      dejavu = true unless a.empty?
    end
    $speaker.speak_up("#{category.to_s.titleize} entry #{entry.join} already seen", 0) if dejavu
    dejavu
  end

  def self.entry_seen(category, entry)
    entry = YAML.load(entry) if entry.is_a?(String) && entry.match(/^\[.*\]$/)
    entry = entry.join if entry.is_a?(Array)
    $db.insert_row('seen', {:category => category, :entry => entry.downcase.gsub(' ', '')})
  end

  def self.entry_delete(category, entry)
    entry = [entry] unless entry.is_a?(Array)
    entry.each do |e|
      $db.delete_rows('seen', {:category => category}, {'entry like' => "%#{e.downcase.gsub(' ', '')}%"})
    end
  end

  def self.object_pack(object, to_hash_only = 0)
    obj = object.clone
    oclass = obj.class.to_s
    if [String, Integer, Float, BigDecimal, Date, DateTime, Time, NilClass].include?(obj.class)
      obj = obj.to_s
    elsif obj.is_a?(Array)
      obj.each_with_index { |o, idx| obj[idx] = object_pack(o, to_hash_only) }
    elsif obj.is_a?(Hash)
      obj.keys.each { |k| obj[k] = object_pack(obj[k], to_hash_only) }
    else
      obj = object.instance_variables.each_with_object({}) { |var, hash| hash[var.to_s.delete("@")] = object_pack(object.instance_variable_get(var), to_hash_only) }
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
        object.keys.each { |k| object[k] = object_unpack(object[k]) } rescue nil
      else
        object = Object.const_get(object[0]).new(object_unpack(object[1])) rescue object_unpack(object[1])
      end
    elsif object.is_a?(Array)
      object.each_with_index { |o, idx| object[idx] = object_unpack(o) }
    else
      object.keys.each { |k| object[k] = object_unpack(object[k]) }
    end
    object
  end

  def self.queue_state_add_or_update(qname, el)
    h = queue_state_get(qname)
    queue_state_save(qname, h.merge(el))
  end

  def self.queue_state_get(qname)
    return @tqueues[qname] if @tqueues[qname]
    res = $db.get_rows('queues_state', {:queue_name => qname}).first
    @tqueues[qname] = object_unpack(res[:value]) rescue {}
    @tqueues[qname]
  end

  def self.queue_state_remove(qname, key)
    h = queue_state_get(qname)
    h.delete(key)
    queue_state_save(qname, h)
  end

  def self.queue_state_save(qname, value)
    Utils.lock_block(__method__.to_s + qname) {
      @tqueues[qname] = value
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
    return h.select { |k, v| block.call(k, v) } if save == 0
    queue_state_save(qname, h.select { |k, v| block.call(k, v) })
  end

  def self.queue_state_shift(qname)
    h = queue_state_get(qname)
    el = h.shift
    queue_state_save(qname, h)
    el
  rescue
    nil
  end
end
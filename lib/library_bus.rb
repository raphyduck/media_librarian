class LibraryBus

  @buses = {}
  @jobs_cache = Queue.new

  def self.bus_get(thread = Thread.current, omni = 0)
    t = thread
    while t[:parent] && (t[:parent][:base_thread].nil? || omni > 0)
      t = t[:parent]
    end
    t
  end

  def self.bus_id(thread = Thread.current)
    bus_get(thread)[:jid].to_s == '' ? 'nodaemon' : bus_get(thread)[:jid]
  end

  def self.bus_variable_get(vname, thread = Thread.current)
    bus_get(thread, 1)[vname]
  end

  def self.bus_variable_set(vname, value, thread = Thread.current)
    if value
      BusVariable.add_bus_variables(vname, thread)
    else
      BusVariable.remove_bus_variables(vname, thread)
    end
    bus_get(thread, 1)[vname] = value
  end

  def self.cache_add(j)
    @jobs_cache << j
  end

  def self.cache_fetch
    @jobs_cache.pop unless @jobs_cache.empty?
  end

  def self.cache_size
    @jobs_cache.length
  end

  def self.initialize_queue(thread = Thread.current)
    @buses[bus_id(thread)] = Queue.new unless @buses[bus_id(thread)]
  end

  def self.merge_queue(thread = Thread.current)
    return nil unless @buses[bus_id(thread)]
    result = nil
    loop do
      break if @buses[bus_id(thread)].empty?
      r = @buses[bus_id(thread)].pop
      if [String, Integer, Float, BigDecimal, Array, Hash, Vash].include?(r.class) && (result.nil? || r.class == result.class)
        result ? result += r : result = r
      end
    end
    result
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    nil
  end

  def self.put_in_queue(value, thread = Thread.current)
    if value.nil?
      $speaker.speak_up("Value of thread[#{thread[:object]}] is nil", 0) if Env.debug?
      return
    end
    if @buses[bus_id(thread)].nil?
      $speaker.speak_up "Queue '#{bus_id(thread)}' is not initialized" if Env.debug?
      return
    end
    @buses[bus_id(thread)] << value
  end

  def self.thread_burn(thread, variable)
    thread_burn = thread[variable].dup
    thread[variable] = nil
    thread_burn
  end

end
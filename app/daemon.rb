class Daemon < EventMachine::Connection

  @last_execution = {}
  @last_email_report = {}
  @queues = {}
  @jobs_cache = Queue.new

  @is_daemon = false
  @is_quitting = false
  @childs_sum = {}
  @daemons = []
  @worker_clearance = Queue.new

  def self.clear_waiting_worker(worker)
    return if worker[:queue_name].to_s == '' || worker[:jid].to_s == ''
    @worker_clearance << [worker, :waiting_threads]
  end

  def self.clear_workers
    loop do
      worker, queue_clearance_name = @worker_clearance.empty? ? nil : @worker_clearance.pop
      break if worker.nil?
      begin
        @queues[worker[:queue_name]][queue_clearance_name].delete_if do |t|
          if queue_clearance_name == :waiting_threads
            worker[:jid] == t[:jid]
          elsif queue_clearance_name == :threads
            worker[:jid] == t[:jid]
          end
        end
        @queues[worker[:queue_name]][:waiting_threads] << worker if queue_clearance_name == :threads
      rescue
      end
    end
  end

  def self.consolidate_children(thread = Thread.current)
    thread[:waiting_for] = 1
    wait_for_children(thread)
    thread[:waiting_for] = nil
    LibraryBus.merge_queue(thread)
  end

  def self.dump_env_flags(expiration = 43200)
    env_flags = {}
    $env_flags.keys.each {|k| env_flags[k.to_s] = Thread.current[k]}
    env_flags['expiration_period'] = expiration
    env_flags
  end

  def self.ensure_daemon
    unless is_daemon?
      $speaker.speak_up 'No daemon running'
      return false
    end
    true
  end

  def self.get_children_count(qname, skip_jid = nil)
    get_workers_count(qname, skip_jid) + (@queues[qname][:jobs] rescue []).length + Thread.current[:job_added].to_i
  end

  def self.get_workers_count(qname, skip_jid = nil)
    return 0 if qname.nil? || @queues[qname].nil?
    (@queues[qname][:waiting_threads] + @queues[qname][:threads]).select {|t| (skip_jid.nil? || t[:jid].to_i != skip_jid.to_i)}.count
  end

  def self.init_queue(qname, task = '')
    @queues[qname] = {} if @queues[qname].nil?
    @queues[qname][:task_name] = task if task != ''
    @queues[qname][:jobs] = [] if @queues[qname][:jobs].nil?
    @queues[qname][:threads] = [] if @queues[qname][:threads].nil?
    @queues[qname][:waiting_threads] = [] if @queues[qname][:waiting_threads].nil?
  end

  def self.is_daemon?
    @is_daemon
  end

  def self.job_id
    (Time.now.to_f * 1000).to_i.to_s + rand(9999999).to_s
  end

  def self.launch_command
    @queues.keys.each do |qname|
      next if queues_slot_taken >= max_queue_slots && qname != 'status'
      (0...max_pool_size(qname)).each do
        break if @queues[qname][:jobs].empty? || get_workers_count(qname) >= max_pool_size(qname)
        args = @queues[qname][:jobs].pop
        @queues[qname][:threads] << Librarian.burst_thread(args[0], args[4], args[8], args[3], args[7], qname) do
          Librarian.run_command(args[5], args[1], args[2], &args[6])
        end
      end
      clear_workers
      remove_queue(qname)
    end
  end

  def self.max_pool_size(qname)
    return [$workers_pool_size.to_i, 1].max unless @queues[qname]
    [(@queues[qname][:max_pool_size] || $workers_pool_size.to_i), 1].max
  end

  def self.max_queue_slots
    [$queue_slots.to_i, 1].max
  end

  def self.merge_notifications(t, parent = Thread.current)
    Utils.lock_time_merge(t, parent)
    return if parent[:email_msg].nil?
    $speaker.speak_up(t[:log_msg].to_s, -1, parent) if t[:log_msg]
    parent[:email_msg] << t[:email_msg].to_s
    parent[:send_email] = t[:send_email].to_i if t[:send_email].to_i > 0
  end

  def self.queue_busy?(qname)
    get_workers_count(qname) >= max_pool_size(qname)
  end

  def self.queues_slot_taken
    @queues.select {|qname, _| queue_slot_taken?(qname)}.count
  end

  def self.queue_slot_taken?(qname)
    (@queues[qname][:threads].select {|w| w&.alive? && w[:waiting_for].nil? && w[:waiting_for_lock].nil?} || []).count > 0
  end

  def self.quit
    if $librarian.quit? && !@is_quitting
      @is_quitting = true
      @is_daemon = false
      thread_cache_add('flush_queues', ['flush_queues'], Daemon.job_id, 'flush', 1) {
        EventMachine::stop
      }
    end
  end

  def self.reload
    #TODO: Fix me, when a command is issued before the daemon is reloaded, the pid file is never created
    return unless ensure_daemon
    $speaker.speak_up('Will reload after pending operations')
    $librarian.reload = true
  end

  def self.remove_queue(qname)
    return if get_children_count(qname).to_i > 0 || qname.nil?
    @queues.delete(qname)
  end

  def self.schedule(jobs)
    ['periodic', 'continuous'].each do |type|
      (jobs[type] || {}).each do |task, params|
        args = params['command'].split('.')
        args += params['args'].map {|a, v| "--#{a}=#{v.to_s}"} if params['args'].is_a?(Hash)
        args += params['args'] if params['args'].is_a?(Array)
        case type
        when 'periodic'
          freq = Utils.timeperiod_to_sec(params['every']).to_i
          thread_cache_add(task, args, job_id, task, 0, 1, 0, Thread.current[:current_daemon], params['expiration'] || 43200) if @last_execution[task].nil? || Time.now > @last_execution[task] + freq.seconds
        when 'continuous'
          if queue_busy?(task)
            if !@last_email_report[task].is_a?(Time) || @last_email_report[task] + 12.hours < Time.now
              @queues[task][:threads].each do |t|
                Report.sent_out(task, t)
                @last_email_report[task] = Time.now
              end
            end
          else
            thread_cache_add(task, args + ["--continuous=1"], job_id, task, 0, 1, 1)
          end
        end
      end
    end
    thread_cache_fetch
    launch_command
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
  end

  def self.start(scheduler: 'scheduler')
    return $speaker.speak_up 'Daemon already started' if is_daemon?
    jobs = $args_dispatch.load_template(scheduler, $template_dir)
    $speaker.speak_up("Will now work in the background")
    $librarian.daemonize
    $librarian.write_pid
    @is_daemon = true
    EventMachine.run do
      start_server($api_option)
      EM.add_periodic_timer(0.2) {schedule(jobs)}
      EM.add_periodic_timer(1) {Librarian.burst_thread {quit}}
    end
    $librarian.delete_pid
    $speaker.speak_up('Shutting down')
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
  end

  def self.start_server(opts = {})
    Thread.current[:base_thread] = 1
    EventMachine.start_server opts['bind_address'], opts['listen_port'], self
  end

  def self.status
    return $speaker.speak_up 'Not in daemon mode' unless is_daemon?
    bq = 0
    @queues.each do |qname, _|
      bq += 1 if queue_busy?(qname)
    end
    $speaker.speak_up "Total queues: #{@queues.keys.count}"
    $speaker.speak_up "Working queues: #{queues_slot_taken}"
    $speaker.speak_up "Busy queues: #{bq}"
    $speaker.speak_up LINE_SEPARATOR
    @queues.keys.each do |qname|
      wc = @queues[qname][:threads].compact.dup
      wwc = @queues[qname][:waiting_threads].compact.dup
      $speaker.speak_up "Queue #{qname}#{' (' + @queues[qname][:task_name].to_s + ')' if @queues[qname][:task_name].to_s != ''}#{' (slot taken)' if queue_slot_taken?(qname)}:"
      $speaker.speak_up " * #{wc.count} worker(s) (max #{max_pool_size(qname)})"
      wc.each do |w|
        childs = get_children_count(w[:jid])
        $speaker.speak_up "   -Job '#{w[:object]}' (jid '#{w[:jid]}' from queue '#{w[:queue_name]}')\
#{' working for ' + TimeUtils.seconds_in_words(Time.now - w[:start_time]) if w[:start_time]}\
#{' waiting for ' + childs.to_s + ' childs' if childs.to_i > 0},#{Utils.lock_time_get(w)}\
#{' (WARNING: Worker is dead' unless w.alive? || (Time.now - w[:end_time]).to_i < 5}\
#{' for ' + TimeUtils.seconds_in_words(Time.now - w[:end_time]) if w[:end_time] && (Time.now - w[:end_time]).to_i >= 5}\
#{ '!)' unless w.alive? || (Time.now - w[:end_time]).to_i < 5}"
      end
      if wwc && wwc.count > 0
        $speaker.speak_up " * Finished jobs waiting for completion of children:"
        wwc.each do |w|
          childs = get_children_count(w[:jid])
          $speaker.speak_up "   -Job '#{w[:object]}' (jid '#{w[:jid]}' from queue '#{w[:queue_name]})\
#{' started ' + TimeUtils.seconds_in_words(Time.now - w[:start_time]) if w[:start_time]} ago\
#{', waiting for ' + childs.to_s + ' childs'}"
        end
      end
      $speaker.speak_up " * #{@queues[qname][:jobs].count} in queue"
      $speaker.speak_up LINE_SEPARATOR
    end
    $speaker.speak_up LINE_SEPARATOR
    bus_vars = BusVariable.list_bus_variables
    $speaker.speak_up "Bus Variables:" unless bus_vars.empty?
    bus_vars.each do |vname|
      v = LibraryBus.bus_variable_get(vname)
      $speaker.speak_up " * Variable '#{vname}': Type '#{v.class}'#{', with ' + v.length.to_s + ' elements' if [Hash, Vash, Array].include?(v.class)}"
    end
    $speaker.speak_up LINE_SEPARATOR
    $speaker.speak_up "Global lock time:#{Utils.lock_time_get}"
    $speaker.speak_up LINE_SEPARATOR
  end

  def self.stop
    return unless ensure_daemon
    $speaker.speak_up('Will shutdown after pending operations')
    $librarian.quit = true
  end

  def self.terminate_worker(worker)
    return if worker[:queue_name].to_s == ''
    @worker_clearance << [worker, :threads]
  end

  def self.thread_cache_add(queue, args, jid, task, internal = 0, max_pool_size = 0, continuous = 0, client = Thread.current[:current_daemon], expiration = 43200, child = 0, &block)
    return if queue.nil?
    Thread.current[:job_added] = 1
    @jobs_cache << [queue, args, jid, task, internal, max_pool_size, client, child, Thread.current, dump_env_flags(continuous.to_i > 0 ? 0 : expiration), block]
  end

  def self.thread_cache_fetch
    loop do
      job = @jobs_cache.empty? ? nil : @jobs_cache.pop
      break if job.nil?
      queue, args, jid, task, internal, max_pool_size, client, child, parent, env_flags, block = job
      return if queue.nil?
      init_queue(queue, task)
      parent[:job_added] = nil
      @queues[queue][:max_pool_size] = max_pool_size if max_pool_size.to_i > 0
      @queues[queue][:jobs] << [jid, internal, task, env_flags, client, args, block, child, parent]
      @last_execution[task] = Time.now
    end
  end

  def self.wait_for_children(thread)
    while get_children_count(thread[:jid]).to_i > 0
      sleep 5
    end
  end

  def post_init
    @client = nil
  end

  def receive_data(data)
    data = YAML.load(data.gsub('=>', ': ')) rescue data
    if data.is_a?(Array) && !@client.nil?
      if data[0].to_s.downcase == 'daemon'
        q = 'status'
      else
        q = data[0..1].join(' ')
      end
      Daemon.thread_cache_add(q, data, Daemon.job_id, q, 0, 1, 0, self) {
        self.send_data('bye')
      }
    else
      case data.to_s
      when /^hello from/
        @client = data.gsub('hello from ', '').to_s
        send_data('listening')
      when /^user_input/
        $speaker.user_input(data.to_s.gsub('user_input ', ''))
      else
        send_data('identify yourself first')
      end
    end
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
  end
end
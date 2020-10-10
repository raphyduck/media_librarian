class Daemon < EventMachine::Connection

  @last_execution = {}
  @last_email_report = {}
  @queues = {}
  @jobs_cache = Queue.new
  JOB_CLEAR_TRIES = 10000
  @is_daemon = false
  @is_quitting = false
  @worker_clearance = Queue.new

  def self.clear_queue(pqueue, forward_queue = nil)
    pqueue.delete_if do |_, t|
      if forward_queue && t[:is_active].to_i == 0
        forward_queue[t[:jid]] = t
      end
      t[:is_active].to_i == 0
    end
  end

  def self.clear_waiting_worker(worker, worker_value = nil, object = nil, clear_current = 0)
    return if worker[:queue_name].to_s == '' || worker[:jid].to_s == ''
    if clear_current.to_i > 0
      @queues[worker[:queue_name]][:current_jobs].delete(worker[:jid])
      queue_save(worker[:queue_name]) if @queues[worker[:queue_name]][:save_to_disk].to_i > 0 && !@is_quitting
    end
    @worker_clearance << [worker, worker_value, object, JOB_CLEAR_TRIES]
  end

  def self.clear_workers
    spin = 0
    loop do
      break if spin.to_i > 1000
      worker, worker_value, object, tries = @worker_clearance.empty? ? nil : @worker_clearance.pop
      break if worker.nil?
      qname = worker[:queue_name]
      begin
        if @queues[qname][:threads][worker[:jid]]
          @queues[qname][:waiting_threads][worker[:jid]] = worker
          @queues[qname][:threads].delete(worker[:jid])
        elsif @queues[qname][:waiting_threads][worker[:jid]]
          @queues[qname][:waiting_threads].delete(worker[:jid])
          Librarian.terminate_command(worker[:parent], worker_value, object) if worker[:parent] && @queues[worker[:parent][:queue_name]]
        elsif tries.to_i > 0
          @worker_clearance << [worker, worker_value, object, (tries - 1)]
        else
          clear_queue(@queue[qname][:waiting_threads])
          clear_queue(@queue[qname][:threads], @queue[qname][:waiting_threads])
        end
      rescue => e
        $speaker.tell_error(e, "Daemon.clear_workers block worker('#{DataUtils.dump_variable(worker)}')")
      end
      queue_remove(qname)
      spin += 1
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
    $env_flags.keys.each { |k| env_flags[k.to_s] = Thread.current[k] }
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

  def self.fetch_function_config(args, config = $available_actions)
    #Will fetch config of function included in $available_actions
    args = args.dup
    config = config[args.shift.to_sym]
    if config.is_a?(Hash)
      fetch_function_config(args, config)
    else
      return config.dup.drop(2)
    end
  rescue
    return []
  end

  def self.get_children_count(qname)
    get_workers_count(qname) + (@queues[qname][:waiting_threads].count rescue 0) + (@queues[qname][:jobs] rescue []).length
  end

  def self.get_workers_count(qname, only_busy = 0)
    return 0 if qname.nil? || @queues[qname].nil?
    @queues[qname][:threads].select { |_, t| (only_busy.to_i == 0 || t[:nonex_lock].to_i == 0) }.count + (@queues[qname][:waiting_threads].count rescue 0) + @queues[qname][:is_new].to_i
  end

  def self.init_queue(qname, task = '', save_to_disk = 0)
    tries ||= 3
    return unless @queues[qname].nil?
    @queues[qname] = {}
    @queues[qname][:is_new] = 1
    @queues[qname][:task_name] = task != '' ? task : qname
    @queues[qname][:jobs] = [] if @queues[qname][:jobs].nil?
    @queues[qname][:threads] = {} if @queues[qname][:threads].nil?
    @queues[qname][:waiting_threads] = {} if @queues[qname][:waiting_threads].nil?
    @queues[qname][:save_to_disk] = save_to_disk
    @queues[qname][:current_jobs] = {} if @queues[qname][:current_jobs].nil?
  rescue
    retry unless (tries -= 1) < 0
  end

  def self.is_daemon?
    @is_daemon
  end

  def self.job_id
    (Time.now.to_f * 1000).to_i.to_s + rand(9999999).to_s
  end

  def self.kill(jid:)
    @queues.each do |_, q|
      (q[:threads] + q[:waiting_threads]).each do |j, w|
        next if jid.to_s != 'all' && j.to_s != jid.to_s
        next unless w
        kill_job(w)
        return 1 if jid.to_s != 'all'
      end
    end
    $speaker.speak_up "No job found with ID '#{jid}'!" if jid.to_s != 'all'
  end

  def self.kill_job(w)
    @queues[w[:jid]][:clearing] = 1 if w[:jid].to_i > 0 && @queues[w[:jid]]
    waiter = 0
    while w[:jid].to_i > 0 && get_children_count(w[:jid]).to_i > 0 && waiter < 10
      $speaker.speak_up "Waiting for child jobs to clear up..."
      waiter += 1
      sleep 1
    end
    $speaker.speak_up "Killing job '#{w[:object]}' from queue '#{w[:queue_name]}'"
    Librarian.run_termination(w, nil, "Killed job #{w[:object]}")
    w.kill if w.alive?
  end

  def self.launch_command
    clear_workers
    @queues.keys.each do |qname|
      if @queues[qname][:clearing].to_i > 0
        queue_clear(qname)
        next
      end
      next if queues_slot_taken >= max_queue_slots && qname != 'priority'
      (0...max_pool_size(qname)).each do
        break if @queues[qname][:jobs].empty? || get_workers_count(qname, max_pool_size(qname) - 1) >= max_pool_size(qname)
        args = @queues[qname][:jobs].pop
        @queues[qname][:current_jobs][args[0]] = args.dup
        @queues[qname][:threads][args[0]] = Librarian.burst_thread(args[0], args[4], args[8], args[3], args[7], qname) do
          Librarian.run_command(args[5].dup, args[1], args[2], &args[6])
        end
      end
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
    get_workers_count(qname, max_pool_size(qname) - 1) >= max_pool_size(qname)
  end

  def self.queue_clear(qname)
    $speaker.speak_up "Clearing queue '#{qname}'"
    @queues[qname][:threads].each { |_, t| kill_job(t) }
    @queues[qname][:waiting_threads].each { |_, t| kill_job(t) }
    @queues[qname][:jobs] = []
    @queues[qname].delete(:is_new)
    queue_remove(qname)
  end

  def self.queue_remove(qname)
    return if get_children_count(qname).to_i > 0 || qname.nil?
    $speaker.speak_up "Removing empty queue '#{qname}'"
    @queues.delete(qname)
  end

  def self.queues_restore
    Cache.queue_state_get('daemon_queues', Hash).each do |qname, v|
      $speaker.speak_up "Restoring jobs from queue '#{qname}'"
      v.each do |args|
        thread_cache_add(qname, args[5], args[0], args[2], args[1], fetch_function_config(args[5])[0] || 1, 0, fetch_function_config(args[5])[2] || 0)
      end
    end
  end

  def self.queue_save(qname)
    $speaker.speak_up "Saving queue '#{qname}'"
    Cache.queue_state_add_or_update('daemon_queues', {qname => (@queues[qname][:jobs] + @queues[qname][:current_jobs].map { |_, j| j })}, 1, 1)
  end

  def self.queues_save
    @queues.keys.each { |qname| queue_save(qname) if @queues[qname][:save_to_disk].to_i > 0 }
  end

  def self.queues_slot_taken
    @queues.select { |qname, _| queue_slot_taken?(qname) }.count
  end

  def self.queue_slot_taken?(qname)
    (@queues[qname][:threads].select { |_, w| w&.alive? && w[:waiting_for].nil? && (max_pool_size(qname) <= 1 || w[:nonex_lock].to_i == 0) } || []).count > 0
  end

  def self.quit
    if $librarian.quit? && !@is_quitting
      @is_quitting = true
      @is_daemon = false
      queues_save
      kill(jid: 'all')
      EventMachine::stop
    end
  end

  def self.reload
    #TODO: Fix me, when a command is issued before the daemon is reloaded, the pid file is never created
    return unless ensure_daemon
    $speaker.speak_up('Will reload after pending operations')
    $librarian.reload = true
  end

  def self.schedule(scheduler)
    @jobs ||= $args_dispatch.load_template(scheduler, $template_dir)
    ['periodic', 'continuous'].each do |type|
      (@jobs[type] || {}).each do |task, params|
        args = params['command'].split('.')
        args += params['args'].map { |a, v| "--#{a}=#{v.to_s}" } if params['args'].is_a?(Hash)
        args += params['args'] if params['args'].is_a?(Array)
        case type
        when 'periodic'
          freq = Utils.timeperiod_to_sec(params['every']).to_i
          thread_cache_add(Daemon.fetch_function_config(args)[1] || task, args, job_id, task, 0, 1, 0, 0, Thread.current[:current_daemon], params['expiration'] || 43200) if @last_execution[task].nil? || Time.now > @last_execution[task] + freq.seconds
        when 'continuous'
          if queue_busy?(task)
            if !@last_email_report[task].is_a?(Time) || @last_email_report[task] + 12.hours < Time.now
              @queues[task][:threads].each do |_, t|
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
    $speaker.speak_up("Will now work in the background")
    $librarian.daemonize
    $librarian.write_pid
    Logger.renew_logs($config_dir + '/log')
    @is_daemon = true
    queues_restore
    EventMachine.run do
      start_server($api_option)
      EM.add_periodic_timer(0.2) { schedule(scheduler) }
      EM.add_periodic_timer(1) { quit }
      EM.add_periodic_timer(3700) { TraktAgent.get_trakt_token }
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
      wcw = @queues[qname][:threads].compact.select { |_, t| t[:nonex_lock].to_i == 0 }
      wcl = @queues[qname][:threads].compact.select { |_, t| t[:nonex_lock].to_i > 0 }
      wwc = @queues[qname][:waiting_threads].compact.dup
      $speaker.speak_up "Queue #{qname}#{' (' + @queues[qname][:task_name].to_s + ')' if @queues[qname][:task_name].to_s != ''}#{' (slot taken)' if queue_slot_taken?(qname)}:"
      $speaker.speak_up "#{SPACER}* #{wcw.count} worker(s) (max #{max_pool_size(qname)})"
      wcw.each do |_, w|
        status_worker(w, 1)
      end
      if wcl.count > 0
        $speaker.speak_up "#{SPACER}* Jobs locked out with non exclusive lock, waiting for release of their lock:"
        wcl.values[0..10].each do |w|
          status_worker(w, 1)
        end
        $speaker.speak_up "#{SPACER}and #{wcl.values[11..-1].count} more" unless wcl.values[11..-1].nil?
      end
      if wwc && wwc.count > 0
        $speaker.speak_up "#{SPACER}* Finished jobs waiting for completion of children:"
        wwc.values[0..10].each do |w|
          status_worker(w)
        end
        $speaker.speak_up "#{SPACER}and #{wwc.values[11..-1].count} more" unless wwc.values[11..-1].nil?
      end
      $speaker.speak_up "#{SPACER}* #{@queues[qname][:jobs].count} in queue"
      $speaker.speak_up LINE_SEPARATOR
    end
    $speaker.speak_up LINE_SEPARATOR
    bus_vars = BusVariable.list_bus_variables
    $speaker.speak_up "Bus Variables:" unless bus_vars.empty?
    bus_vars.each do |vname|
      v = LibraryBus.bus_variable_get(vname)
      $speaker.speak_up "#{SPACER}* Variable '#{vname}': Type '#{v.class}'#{', with ' + v.length.to_s + ' elements' if [Hash, Vash, Array].include?(v.class)}"
    end
    $speaker.speak_up LINE_SEPARATOR
    $speaker.speak_up "Global lock time:#{Utils.lock_time_get}"
    $speaker.speak_up LINE_SEPARATOR
  end

  def self.status_worker(worker, warn = 0)
    childs = get_children_count(worker[:jid])
    warning = warn > 1 ? "#{" (WARNING: Worker is dead" unless worker.alive? || (Time.now - worker[:end_time]).to_i < 5}\
    #{"for " + TimeUtils.seconds_in_words(Time.now - worker[:end_time]) if worker[:end_time] && (Time.now - worker[:end_time]).to_i >= 5}\
    #{" !)" unless worker.alive? || (Time.now - worker[:end_time]).to_i < 5}" : ''
    $speaker.speak_up "#{SPACER * 2}-Job '#{worker[:object]}' (jid '#{worker[:jid]}' from queue '#{worker[:queue_name]}')\
#{" working for " + TimeUtils.seconds_in_words(Time.now - worker[:start_time]) if worker[:start_time]}\
#{" waiting for " + childs.to_s + ' childs' if childs.to_i > 0},#{Utils.lock_time_get(worker)}\
#{" locked by '#{worker[:locked_by]}'" if worker[:locked_by]}#{warning}"
  end

  def self.stop
    return unless ensure_daemon
    $speaker.speak_up('Will shutdown after pending operations')
    $librarian.quit = true
  end

  def self.thread_cache_add(queue, args, jid, task, internal = 0, max_pool_size = 0, continuous = 0, save_to_disk = 0, client = Thread.current[:current_daemon], expiration = 43200, child = 0, &block)
    return if queue.nil?
    init_queue(queue, task, save_to_disk)
    @jobs_cache << [queue, args, jid, task, internal, max_pool_size, client, child, Thread.current, dump_env_flags(continuous.to_i > 0 ? 0 : expiration), block]
  end

  def self.thread_cache_fetch
    loop do
      job = @jobs_cache.empty? ? nil : @jobs_cache.pop
      break if job.nil?
      queue, args, jid, task, internal, max_pool_size, client, child, parent, env_flags, block = job
      return if queue.nil?
      @queues[queue][:max_pool_size] = max_pool_size if max_pool_size.to_i > 0
      @queues[queue][:jobs] << [jid, internal, task, env_flags, client, args, block, child, parent]
      @queues[queue].delete(:is_new)
      @last_execution[task] = Time.now
      queue_save(queue) if @queues[queue][:save_to_disk].to_i > 0
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
      qconf = Daemon.fetch_function_config(data)
      Daemon.thread_cache_add(qconf[1] || data[0..1].join(' '), data, Daemon.job_id, qconf[1] || data[0..1].join(' '), 0, qconf[0] || 1, 0, qconf[2] || 0, self) {
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
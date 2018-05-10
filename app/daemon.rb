class Daemon < EventMachine::Connection

  @last_execution = {}
  @threads = {}
  @last_flush = Time.now
  @last_email_report = Time.now
  @queues = {}
  @queues_max_pool = {}
  @is_daemon = false
  @is_quitting = false
  @daemons = []

  def self.decremente_children(t)
    t[:childs] -= 1 if t[:childs]
  end

  def self.get_workers_count(qname)
    @threads[qname] = {} if @threads[qname].nil?
    @threads[qname]['working'] = [] unless @threads[qname]['working']
    @threads[qname]['working'].delete_if do |t|
      if t[:start_time].is_a?(Time) && t[:expiration_period].to_i > 0 && t[:start_time] < Time.now - t[:expiration_period].to_i.seconds
        Report.sent_out("Stuck job #{t[:object].to_s} (jid '#{t[:jid].to_s}')", nil, "Job '#{t[:object].to_s}' (jid '#{t[:jid]}') is stuck, (started at #{t[:start_time].to_s}), will be killed")
        t.kill
      end
      t = nil unless t.alive?
      t.nil?
    end
    @threads[qname]['working'].count
  end

  def self.incremente_children(t)
    t[:childs] = 0 if t[:childs].nil?
    t[:childs] += 1
  end

  def self.is_daemon?
    @is_daemon
  end

  def self.job_id
    (Time.now.to_f * 1000).to_i.to_s + rand(9999999).to_s
  end

  def self.launch_command
    @queues.each do |qname, q|
      if get_workers_count(qname) < max_pool_size(qname)
        args = q.shift
        next if args.nil?
        t = Librarian.burst_thread(args[4], args[7]) { Librarian.run_command(args[5], args[1], args[2], args[3], &args[6]) }
        t[:jid] = args[0]
        @threads[qname]['working'] << t
      end
    end
  end

  def self.max_pool_size(qname)
    [(@queues_max_pool[qname] || $workers_pool_size.to_i), 1].max
  end

  def self.merge_notifications(t, parent = Thread.current)
    return if parent[:email_msg].nil?
    parent[:email_msg] << t[:email_msg].to_s
    parent[:send_email] = t[:send_email].to_i if t[:send_email].to_i > 0
  end

  def self.queue_busy?(qname)
    get_workers_count(qname) >= max_pool_size(qname)
  end

  def self.quit
    if $librarian.quit && !@is_quitting
      @is_quitting = true
      thread_cache_add('exclusive', ['flush_queues'], Daemon.job_id, 'flush', 1) {
        EventMachine::stop
      }
    end
  end

  def self.schedule(jobs)
    ['periodic', 'continuous'].each do |type|
      (jobs[type] || {}).each do |task, params|
        args = params['command'].split('.')
        args += params['args'].map { |a, v| "--#{a}=#{v.to_s}" } if params['args'].is_a?(Hash)
        args += params['args'] if params['args'].is_a?(Array)
        case type
          when 'periodic'
            freq = Utils.timeperiod_to_sec(params['every']).to_i
            thread_cache_add('exclusive', args, job_id, task, 0, params['max_pool_size'] || 0, 0, Thread.current[:current_daemon], params['expiration'] || 43200) if @last_execution[task].nil? || Time.now > @last_execution[task] + freq.seconds
          when 'continuous'
            if queue_busy?(task)
              if @last_email_report + 12.hours < Time.now
                @threads[task]['working'].each do |t|
                  Report.sent_out(task, t)
                end
                @last_email_report = Time.now
              end
            else
              thread_cache_add(task, args + ["--continuous=1"], job_id, task, 0, 1, 1)
            end
        end
      end
    end
    launch_command
    if @last_flush + 60.minutes < Time.now
      thread_cache_add('exclusive', ['flush_queues'], Daemon.job_id, 'flush queues')
      @last_flush = Time.now
    end
  rescue => e
    $speaker.tell_error(e, "Daemon.schedule(jobs)")
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
      EM.add_periodic_timer(1) { schedule(jobs) }
      EM.add_periodic_timer(1) { Librarian.burst_thread { quit } }
    end
    $speaker.speak_up('Shutting down')
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
    $speaker.speak_up "Busy queues: #{bq} out of #{@queues.map{|k,_| k}.count}"
    $speaker.speak_up LINE_SEPARATOR
    @queues.each do |qname, q|
      wc = get_workers_count(qname)
      $speaker.speak_up "Queue #{qname}:"
      $speaker.speak_up "* #{wc} worker(s) (max #{max_pool_size(qname)})"
      if wc > 0
        @threads[qname]['working'].each do |w|
          $speaker.speak_up "  -Job '#{w[:jid]}' ('#{w[:object]}') #{' working since ' + w[:start_time].to_s if w[:start_time]}#{' waiting for ' + w[:childs].to_s + ' childs' if w[:childs].to_i > 0}" if w.alive?
        end
      end
      $speaker.speak_up "* #{q.count} in queue"
      $speaker.speak_up LINE_SEPARATOR
    end
  end

  def self.stop
    return $speaker.speak_up "No daemon running" unless is_daemon?
    $speaker.speak_up('Will shutdown after pending operations')
    $librarian.quit = true
  end

  def self.thread_cache_add(queue, args, jid, task, internal = 0, max_pool_size = 0, continuous = 0, client = Thread.current[:current_daemon], expiration = 43200, &block)
    env_flags = {}
    $env_flags.keys.each { |k| env_flags[k.to_s] = Thread.current[k] }
    env_flags['expiration_period'] = continuous.to_i > 0 ? 0 : expiration
    @queues[queue] = [] if @queues[queue].nil?
    @queues_max_pool[queue] = max_pool_size if max_pool_size.to_i > 0
    @queues[queue] << [jid, internal, task, env_flags, client, args, block, Thread.current]
    @threads[queue] = {} if @threads[queue].nil?
    @last_execution[task] = Time.now
    incremente_children(Thread.current)
    jid
  end

  def post_init
    @client = nil
  end

  def receive_data(data)
    data = YAML.load(data.gsub('=>', ': ')) rescue data
    if data.is_a?(Array) && !@client.nil?
      if data[0].to_s.downcase == 'daemon' && data[1].to_s.downcase == 'status'
        q = 'status'
      else
        q = 'exclusive'
      end
      Daemon.thread_cache_add(q, data, Daemon.job_id, 'rcv', 0, 0, 0, self) {
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
    $speaker.tell_error(e, "Daemon.new.receive data")
  end
end
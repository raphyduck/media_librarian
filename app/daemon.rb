class Daemon < EventMachine::Connection

  @last_execution = {}
  @threads = {}
  @last_flush = Time.now
  @queues = {}
  @queues_max_pool = {}
  @is_daemon = false
  @is_quitting = false
  @daemons = []

  def self.get_workers_count(qname)
    @threads[qname] = {} if @threads[qname].nil?
    @threads[qname]['working'] = [] unless @threads[qname]['working']
    @threads[qname]['working'].delete_if do |t|
      unless t.alive?
        @threads[qname][t[:jid]] = t
        t = nil
      end
      t.nil?
    end
    @threads[qname]['working'].count
  end

  def self.is_daemon?
    @is_daemon
  end

  def self.job_id
    (Time.now.to_f * 1000).to_i
  end

  def self.launch_command
    @queues.each do |qname, q|
      if get_workers_count(qname) < max_pool_size(qname)
        args = q.shift
        next if args.nil?
        t = Librarian.burst_thread { Librarian.run_command(args[2], args[1]) }
        t[:jid] = args[0]
        @threads[qname]['working'] << t
      end
    end
  end

  def self.max_pool_size(qname)
    [(@queues_max_pool[qname] || $workers_pool_size.to_i), 1].max
  end

  def self.queue_busy?(qname)
    get_workers_count(qname) >= max_pool_size(qname)
  end

  def self.quit
    if $librarian.quit && !@is_quitting
      @is_quitting = true
      jid = thread_cache_add('exclusive', ['flush_queues'], Daemon.job_id, 'flush')
      thread_wait('exclusive', jid)
      EventMachine::stop
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
            thread_cache_add('exclusive', args, job_id, task) if @last_execution[task].nil? || Time.now > @last_execution[task] + freq.seconds
          when 'continuous'
            unless queue_busy?(task)
              thread_cache_add(task, args, job_id, task, 0, 1)
            end
        end
      end
    end
    launch_command
    if @last_flush + 60.minutes < Time.now
      thread_cache_add('exclusive', ['flush_queues'], Daemon.job_id, 'flush')
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
    EventMachine.start_server opts['bind_address'], opts['listen_port'], self
  end

  def self.stop
    return $speaker.speak_up "No daemon running" unless is_daemon?
    $speaker.speak_up('Will shutdown after pending operations')
    $librarian.quit = true
  end

  def self.thread_cache_add(queue, args, jid, task, internal = 0, max_pool_size = 0)
    @queues[queue] = [] if @queues[queue].nil?
    @queues_max_pool[queue] = max_pool_size if max_pool_size.to_i > 0
    @queues[queue] << [jid, internal, args]
    @threads[queue] = {} if @threads[queue].nil?
    @last_execution[task] = Time.now
    jid
  end

  def self.thread_wait(queue, jids)
    return {} unless is_daemon?
    jids = [jids] unless jids.is_a?(Array)
    result = {}
    until jids.empty?
      jids.delete_if do |j|
        r = @threads[queue][j]
        if r
          result[j] = {
              :email_msg => r[:email_msg],
              :status => r.status,
              :value => r.value
          }
          @threads[queue].delete(j)
        end
        !r.nil?
      end
      sleep 1
    end
    result
  end

  def post_init
    @client = nil
    Thread.current[:current_daemon] = self
  end

  def receive_data(data)
    data = YAML.load(data.gsub('=>', ': ')) rescue data
    if data.is_a?(Array) && !@client.nil?
      EM.defer(Proc.new do
        jid = Daemon.thread_cache_add('exclusive', data, Daemon.job_id, 'rcv')
        Daemon.thread_wait('exclusive', jid)
      end,
               Proc.new do |_|
                 send_data('bye')
               end)
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
class Daemon < EventMachine::Connection

  @last_execution = {}
  @threads = {}
  @last_flush = Time.now
  @queues = {}
  @is_daemon = false
  @is_quitting = false

  def self.is_daemon?
    @is_daemon
  end

  def self.job_id
    (Time.now.to_f * 1000).to_i
  end

  def self.launch_command
    @queues.each do |qname, q|
      if @threads[qname]['current_thd'] && !@threads[qname]['current_thd'].alive?
        @threads[qname][@threads[qname]['current_jid']] = @threads[qname]['current_thd'].value
        @threads[qname]['current_thd'] = nil
      end
      if @threads[qname]['current_thd'].nil?
        args = q.shift
        next if args.nil?
        @threads[qname]['current_thd'] = Thread.new { $librarian.run_command(args[1]) }
        @threads[qname]['current_jid'] = args[0]
      end
    end
  end

  def self.queue_busy?(qname)
    @threads[qname] && @threads[qname]['current_thd'] && @threads[qname]['current_thd'].alive?
  end

  def self.quit
    if $librarian.quit && !@is_quitting
      @is_quitting = true
      thread_cache_add('exclusive', ['flush_queues'], Daemon.job_id, 'flush', 1)
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
              thread_cache_add(task, args, job_id, task)
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
    jobs = SimpleArgsDispatch.load_template(scheduler, $template_dir)
    $speaker.speak_up("Will now work in the background")
    $librarian.daemonize
    $librarian.write_pid
    @is_daemon = true
    EventMachine.run do
      start_server($api_option)
      EM.add_periodic_timer(1) { schedule(jobs) }
      EM.add_periodic_timer(1) { Thread.new { quit } }
    end
    $speaker.speak_up('Shutting down')
  end

  def self.start_server(opts = {})
    EventMachine.start_server opts['bind_address'], opts['listen_port'], self
  end

  def self.stop
    return $speaker.speak_up "No daemon running" unless is_daemon?
    $daemon_server.send_data('Will shutdown after pending operations')
    $librarian.quit = true
  end

  def self.thread_cache_add(queue, args, jid, task, wait = 0)
    @queues[queue] = [] if @queues[queue].nil?
    @queues[queue] << [jid, args]
    @threads[queue] = {} if @threads[queue].nil?
    @last_execution[task] = Time.now
    result = @threads[queue][jid]
    while wait.to_i > 0 && result.nil?
      sleep 5
      result = @threads[queue][jid]
    end
    result
  end

  def post_init
    @client = nil
    $daemon_server = self
  end

  def receive_data(data)
    data = eval(data) rescue data
    if data.is_a?(Array) && !@client.nil?
      EM.defer(Proc.new do
        Daemon.thread_cache_add('exclusive', data, Daemon.job_id, 'rcv', 1)
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
          $user_input = data.to_s.gsub('user_input ', '')
        else
          send_data('identify yourself first')
      end
    end
  rescue => e
    $speaker.tell_error(e, "Daemon.new.receive data")
  end
end
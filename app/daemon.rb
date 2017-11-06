class Daemon

  @last_execution = {}
  @threads = {}
  @low_bandwidth = 0
  @last_flush = Time.now
  @queues = {}

  def self.launch_command
    @queues.each do |qname, q|
      @threads[qname]['t'] = nil if @threads[qname]['t'] && !@threads[qname]['t'].alive?
      if @threads[qname]['t'].nil?
        args = q.shift
        $speaker.speak_up("Launching #{args.join(' ')} for queue #{qname}", 0)
        @threads[qname]['t'] = Thread.new { SimpleArgsDispatch.dispatch(APP_NAME, args, $available_actions, nil, $template_dir) }
      end
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
            thread_cache_add('exclusive', args, task) if @last_execution[task].nil? || Time.now > @last_execution[task] + freq.seconds
          when 'continuous'
            if params['monitor_bandwidth'].is_a?(Hash) && params['monitor_bandwidth']['network_card'].to_s != '' && params['monitor_bandwidth']['min_bandwidth'] > 0
              in_speed, _ = Utils.get_traffic(params['monitor_bandwidth']['network_card'])
              if in_speed < params['monitor_bandwidth']['min_bandwidth'] / 4
                @low_bandwidth += 1
              else
                @low_bandwidth = 0
              end
            end
            while (!Utils.check_if_active(params['active_hours']) || @low_bandwidth > 4) && (@threads[task]['t'] && @threads[task]['t'].alive?)
              Report.sent_out(task)
              $speaker.speak_up("Shutting down #{task}", 0)
              @threads[task]['t'].exit
            end
            thread_cache_add(task, args, task) if Utils.check_if_active(params['active_hours'])
        end
        launch_command
      end
    end
    $librarian.flush_queues if @last_flush + 60.minutes < Time.now
  rescue => e
    $speaker.tell_error(e, "Daemon.schedule(jobs)")
  end

  def self.start(scheduler: 'scheduler')
    jobs = SimpleArgsDispatch.load_template(scheduler, $template_dir)
    $speaker.speak_up("Will now work in the background")
    $librarian.daemonize
    $librarian.write_pid
    while !$librarian.quit
      schedule(jobs)
      sleep(10)
    end
    $speaker.speak_up('Shutting down')
  end

  def self.thread_cache_add(queue, args, task)
    @queues[queue] = [] if @queues[queue].nil?
    @queues[queue] << args
    @threads[queue] = {} if @threads[queue].nil?
    @last_execution[task] = Time.now
  end
end
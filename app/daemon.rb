# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'time'
require 'webrick'
require 'concurrent-ruby'

class Daemon
  include MediaLibrarian::AppContainerSupport

  Job = Struct.new(
    :id,
    :queue,
    :args,
    :task,
    :internal,
    :client,
    :env_flags,
    :parent_thread,
    :parent_job_id,
    :child,
    :created_at,
    :started_at,
    :finished_at,
    :status,
    :result,
    :error,
    :future,
    :worker_thread,
    :block,
    keyword_init: true
  ) do
    def running?
      status == :running && finished_at.nil?
    end

    def finished?
      !!finished_at || %i[finished failed cancelled].include?(status)
    end

    def to_h
      effective_status = if finished_at && status == :running
                           'finished'
                         else
                           status.to_s
                         end
      {
        'id' => id,
        'queue' => queue,
        'task' => task,
        'status' => effective_status,
        'created_at' => created_at&.iso8601,
        'started_at' => started_at&.iso8601,
        'finished_at' => finished_at&.iso8601,
        'result' => result,
        'error' => error && error.to_s
      }
    end
  end

  CONTROL_CONTENT_TYPE = 'application/json'

  class << self
    def start(scheduler: 'scheduler', daemonize: true)
      return app.speaker.speak_up('Daemon already started') if running?

      app.speaker.speak_up('Will now work in the background')
      if daemonize
        app.librarian.daemonize
        app.librarian.write_pid
        Logger.renew_logs(app.config_dir + '/log')
      end

      boot_framework_state
      @is_daemon = true

      start_scheduler(scheduler) if scheduler
      start_quit_timer
      start_trakt_timer
      start_control_server

      wait_for_shutdown
    rescue StandardError => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding))
    ensure
      cleanup
      if daemonize
        app.librarian.delete_pid
        app.speaker.speak_up('Shutting down')
      end
    end

    def stop
      return unless ensure_daemon

      app.speaker.speak_up('Will shutdown after pending operations')
      app.librarian.quit = true
      shutdown
    end

    def status
      return app.speaker.speak_up('Not in daemon mode') unless running?

      snapshot = status_snapshot
      app.speaker.speak_up "Total jobs: #{snapshot[:jobs].count}"
      app.speaker.speak_up "Running jobs: #{snapshot[:running].count}"
      app.speaker.speak_up "Queued jobs: #{snapshot[:queued].count}"
      app.speaker.speak_up "Finished jobs: #{snapshot[:finished].count}"
      app.speaker.speak_up LINE_SEPARATOR
      snapshot[:jobs].each do |job|
        app.speaker.speak_up "- Job #{job.id} (queue: #{job.queue}) status=#{job.status}"
      end
      app.speaker.speak_up LINE_SEPARATOR
      app.speaker.speak_up "Global lock time:#{Utils.lock_time_get}"
      app.speaker.speak_up LINE_SEPARATOR
    end

    def status_snapshot
      jobs = job_registry.values
      {
        jobs: jobs,
        running: jobs.select(&:running?),
        queued: jobs.reject(&:finished?).reject(&:running?),
        finished: jobs.select(&:finished?)
      }
    end

    def ensure_daemon
      unless running?
        app.speaker.speak_up 'No daemon running'
        return false
      end
      true
    end

    def running?
      @running&.true?
    end

    def is_daemon?
      running?
    end

    def job_id
      SecureRandom.uuid
    end

    def dump_env_flags(expiration = 43_200)
      env_flags = {}
      app.env_flags.each_key { |k| env_flags[k.to_s] = Thread.current[k] }
      env_flags['expiration_period'] = expiration
      env_flags
    end

    def fetch_function_config(args, config = Librarian.command_registry.actions)
      args = args.dup
      config = config[args.shift.to_sym]
      if config.is_a?(Hash)
        fetch_function_config(args, config)
      else
        config ? config.dup.drop(2) : []
      end
    rescue StandardError
      []
    end

    def consolidate_children(thread = Thread.current)
      wait_for_children(thread)
      LibraryBus.merge_queue(thread)
    end

    def merge_notifications(thread, parent = Thread.current)
      Utils.lock_time_merge(thread, parent)
      return if parent[:email_msg].nil?

      app.speaker.speak_up(thread[:log_msg].to_s, -1, parent) if thread[:log_msg]
      parent[:email_msg] << thread[:email_msg].to_s
      parent[:send_email] = thread[:send_email].to_i if thread[:send_email].to_i.positive?
    end

    def clear_waiting_worker(worker_thread, thread_value = nil, object = nil, _clear_current = 0)
      job = job_for_thread(worker_thread)
      return unless job

      finalize_job(job, thread_value, object)
    end

    def get_children_count(jid)
      children = job_children[jid]
      children ? children.length : 0
    end

    def wait_for_children(thread)
      loop do
        children = job_children[thread[:jid]]
        break if children.nil? || children.empty?

        sleep 1
      end
    end

    def kill(jid:)
      if jid.to_s == 'all'
        job_registry.values.each { |job| cancel_job(job) }
        return 1
      end

      job = job_registry[jid]
      if job
        cancel_job(job)
        1
      else
        app.speaker.speak_up "No job found with ID '#{jid}'!"
        nil
      end
    end

    def enqueue(args:, queue: nil, task: nil, internal: 0, client: Thread.current[:current_daemon], child: 0, env_flags: nil, parent_thread: Thread.current, &block)
      return unless running?

      queue_name = queue || task || args[0..1].join(' ')
      job = Job.new(
        id: job_id,
        queue: queue_name || 'default',
        args: args.dup,
        task: task || queue_name || args[0..1].join(' '),
        internal: internal.to_i,
        client: client,
        env_flags: env_flags || dump_env_flags(child.to_i.positive? ? 0 : 43_200),
        parent_thread: parent_thread,
        child: child,
        created_at: Time.now,
        status: :queued,
        block: block
      )
      register_job(job)
      start_job(job)
      job
    end

    def schedule(scheduler)
      return unless running?

      @template_cache ||= app.args_dispatch.load_template(scheduler, app.template_dir)
      %w[periodic continuous].each do |type|
        next unless @template_cache[type]

        @template_cache[type].each do |task, params|
          args = params['command'].split('.')
          if params['args'].is_a?(Hash)
            args += params['args'].map { |a, v| "--#{a}=#{v}" }
          elsif params['args'].is_a?(Array)
            args += params['args']
          end

          case type
          when 'periodic'
            frequency = Utils.timeperiod_to_sec(params['every']).to_i
            next unless should_run_periodic?(task, frequency)

            enqueue(
              args: args,
              queue: fetch_function_config(args)[1] || task,
              task: task,
              internal: 0,
              client: Thread.current[:current_daemon],
              child: 0,
              env_flags: dump_env_flags(params['expiration'] || 43_200)
            )
            @last_execution[task] = Time.now
          when 'continuous'
            next if queue_busy?(task)

            enqueue(
              args: args + ['--continuous=1'],
              queue: task,
              task: task,
              internal: 0,
              client: Thread.current[:current_daemon],
              child: 0
            )
          end
        end
      end
    rescue StandardError => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding))
    end

    private

    def boot_framework_state
      @running = Concurrent::AtomicBoolean.new(true)
      @stop_event = Concurrent::Event.new
      @last_execution = {}
      @last_email_report = {}
      @template_cache = nil
      @jobs = Concurrent::Hash.new
      @job_children = Concurrent::Hash.new { |h, k| h[k] = Concurrent::Array.new }
      @executor = Concurrent::ThreadPoolExecutor.new(
        min_threads: 1,
        max_threads: [app.workers_pool_size.to_i, 1].max,
        max_queue: 0,
        fallback_policy: :caller_runs
      )
    end

    def register_job(job)
      @jobs[job.id] = job
      parent_thread = job.parent_thread
      parent_jid = parent_thread && parent_thread[:jid]
      return unless parent_jid

      job.parent_job_id = parent_jid
      job_children[parent_jid] << job.id
    end

    def start_job(job)
      job.future = Concurrent::Promises.future_on(@executor) do
        execute_job(job)
      end
      job.future.on_fulfillment! do |value|
        finalize_job(job, value, nil)
      end
      job.future.on_rejection! do |reason|
        finalize_job(job, nil, reason)
      end
      job
    end

    def execute_job(job)
      thread = Thread.current
      job.worker_thread = thread
      thread[:current_daemon] = job.client || thread[:current_daemon]
      thread[:parent] = job.parent_thread
      thread[:jid] = job.id
      thread[:queue_name] = job.queue
      thread[:log_msg] = '' if job.child.to_i.positive?
      LibraryBus.initialize_queue(thread)
      app.args_dispatch.set_env_variables(app.env_flags, job.env_flags || {})
      job.status = :running
      job.started_at = Time.now
      Librarian.run_command(job.args.dup, job.internal, job.task, &job.block)
    ensure
      thread[:jid] = nil
      job.worker_thread = nil
    end

    def finalize_job(job, value, error)
      return if job.finished_at

      job.result = value
      job.finished_at = Time.now
      future = job.future
      cancelled_future = future&.respond_to?(:cancelled?) && future.cancelled?
      if job.status == :cancelled || cancelled_future
        job[:status] = :cancelled
        job[:error] = job.error || error
      elsif error
        job[:status] = :failed
        job[:error] = error
      else
        job[:status] = :finished
        job[:error] = job.error || error
      end
      @jobs[job.id] = job
      unregister_child(job)
    end

    def unregister_child(job)
      return unless job.parent_job_id

      children = job_children[job.parent_job_id]
      children.delete(job.id) if children
    end

    def cancel_job(job)
      future = job.future
      future.cancel if future&.respond_to?(:cancel)
      worker_thread = job.worker_thread
      worker_thread.kill if worker_thread&.alive? && worker_thread != Thread.current
      job[:status] = :cancelled
      job[:error] = 'Cancelled'
      finalize_job(job, nil, nil)
    end

    def start_scheduler(_scheduler)
      @scheduler = Concurrent::TimerTask.new(execution_interval: 0.2) do
        schedule(_scheduler)
      end
      @scheduler.execute
    end

    def start_quit_timer
      @quit_timer = Concurrent::TimerTask.new(execution_interval: 1) { quit }
      @quit_timer.execute
    end

    def start_trakt_timer
      return unless defined?(TraktAgent)

      @trakt_timer = Concurrent::TimerTask.new(execution_interval: 3700) do
        TraktAgent.get_trakt_token
      rescue StandardError => e
        app.speaker.tell_error(e, 'Trakt refresh failure')
      end
      @trakt_timer.execute
    end

    def start_control_server
      opts = app.api_option
      @control_server = WEBrick::HTTPServer.new(
        Port: opts['listen_port'],
        BindAddress: opts['bind_address'],
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: []
      )

      @control_server.mount_proc('/jobs') do |req, res|
        handle_jobs_request(req, res)
      end

      @control_server.mount_proc('/status') do |_req, res|
        res['Content-Type'] = CONTROL_CONTENT_TYPE
        res.body = JSON.dump(status_snapshot[:jobs].map(&:to_h))
      end

      @control_server.mount_proc('/stop') do |_req, res|
        res['Content-Type'] = CONTROL_CONTENT_TYPE
        res.body = JSON.dump('status' => 'stopping')
        Thread.new { stop }
      end

      @control_thread = Thread.new { @control_server.start }
    end

    def handle_jobs_request(req, res)
      case req.request_method
      when 'POST'
        return handle_job_not_found(res) unless req.path == '/jobs'

        payload = parse_payload(req)
        args = Array(payload['command'])
        wait = payload.fetch('wait', true)
        internal = payload['internal'] || 0
        queue = payload['queue']
        task = payload['task']

        job = enqueue(
          args: args,
          queue: queue,
          task: task,
          internal: internal,
          child: payload['child'].to_i,
          env_flags: payload['env_flags'],
          parent_thread: nil
        )

        if wait && job&.future
          job.future.wait
          job.future.value!
        end

        res['Content-Type'] = CONTROL_CONTENT_TYPE
        res.body = JSON.dump('job' => job&.to_h)
      when 'GET'
        return handle_job_not_found(res) unless req.path.start_with?('/jobs/')

        handle_job_lookup(req, res)
      else
        handle_job_not_found(res)
      end
    rescue StandardError => e
      res.status = 422
      res['Content-Type'] = CONTROL_CONTENT_TYPE
      res.body = JSON.dump('error' => e.message)
    end

    def handle_job_lookup(req, res)
      jid = req.path.sub('/jobs/', '')
      job = job_registry[jid]
      if job
        res['Content-Type'] = CONTROL_CONTENT_TYPE
        res.body = JSON.dump(job.to_h)
      else
        handle_job_not_found(res)
      end
    end

    def handle_job_not_found(res)
      res.status = 404
      res['Content-Type'] = CONTROL_CONTENT_TYPE
      res.body = JSON.dump('error' => 'not_found')
    end

    def parse_payload(req)
      return {} if req.body.nil? || req.body.empty?

      JSON.parse(req.body)
    end

    def queue_busy?(queue)
      job_registry.values.any? { |job| job.queue == queue && job.running? }
    end

    def should_run_periodic?(task, frequency)
      last_run = @last_execution[task]
      last_run.nil? || Time.now > last_run + frequency
    end

    def quit
      return unless running?
      return unless app.librarian.quit?

      shutdown
    end

    def shutdown
      return unless running?
      @running.make_false

      [@scheduler, @quit_timer, @trakt_timer].compact.each do |timer|
        timer.shutdown
        timer.wait_for_termination
      end

      @control_server&.shutdown
      @control_thread&.join

      @executor.shutdown
      @executor.wait_for_termination

      @stop_event.set
    end

    def wait_for_shutdown
      @stop_event.wait
    end

    def cleanup
      @scheduler = nil
      @quit_timer = nil
      @trakt_timer = nil
      @control_thread = nil
      @control_server = nil
      @executor = nil
      @template_cache = nil
      @running = nil
      @stop_event = nil
      @is_daemon = false
    end

    def job_registry
      @jobs || {}
    end

    def job_children
      @job_children || {}
    end

    def job_for_thread(thread)
      jid = thread && thread[:jid]
      jid && job_registry[jid]
    end
  end
end

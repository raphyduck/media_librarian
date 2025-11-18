# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'time'
require 'webrick'
require 'webrick/https'
require 'openssl'
require 'ipaddr'
require 'logger'
require 'concurrent-ruby'
require 'bcrypt'
require 'yaml'
require 'fileutils'
require 'base64'
require 'get_process_mem'

require_relative '../lib/logger'
require_relative 'client'
require_relative '../lib/thread_state'

WEBrick::HTTPServlet::ProcHandler.class_eval do
  alias do_DELETE do_GET unless method_defined?(:do_DELETE)
end

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
    :capture_output,
    :output,
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
        'error' => error && error.to_s,
        'output' => output
      }
    end
  end

  CONTROL_CONTENT_TYPE = 'application/json'
  LOG_TAIL_LINES = 10_000
  SESSION_COOKIE_NAME = 'ml_session'
  FINISHED_STATUSES = %w[finished failed cancelled].freeze
  INLINE_EXECUTED = Object.new

  class << self
    def start(scheduler: 'scheduler', daemonize: true)
      daemonize = false if ENV['MEDIA_LIBRARIAN_FOREGROUND'].to_s == '1'
      return app.speaker.speak_up('Daemon already started') if running?

      restart_flag = restart_requested_flag
      manage_pid = daemonize
      daemonized = false
      first_cycle = true

      begin
        loop do
          app.speaker.speak_up(first_cycle ? 'Will now work in the background' : 'Restarting daemon')
          if daemonize && !daemonized
            app.librarian.daemonize
            app.librarian.write_pid
            Logger.renew_logs(app.config_dir + '/log')
            daemonized = true
          end

          begin
            boot_framework_state
            @is_daemon = true
            @scheduler_name = scheduler

            start_scheduler(scheduler) if scheduler
            start_quit_timer
            start_trakt_timer
            start_control_server

            wait_for_shutdown
          rescue StandardError => e
            app.speaker.tell_error(e, Utils.arguments_dump(binding))
          ensure
            cleanup
            app.librarian.quit = false if app.librarian
          end

          break unless restart_flag.true?

          restart_flag.make_false
          first_cycle = false
          daemonize = false
        end
      rescue StandardError => e
        app.speaker.tell_error(e, Utils.arguments_dump(binding))
      ensure
        restart_flag.make_false if restart_flag
        if manage_pid && daemonized
          app.librarian.delete_pid
          app.speaker.speak_up('Shutting down')
        end
      end

      exit if daemonized
    end

    def stop
      if running?
        app.speaker.speak_up('Will shutdown after pending operations')
        app.librarian.quit = true
        if Thread.current[:jid]
          Thread.new { shutdown }
        else
          shutdown
        end
        return true
      end

      response = Client.new.stop
      status_code = response['status_code']

      case status_code
      when 200
        app.speaker.speak_up('Stop command sent to daemon')
        true
      when 401, 403
        app.speaker.speak_up('Not authorized to stop daemon')
        false
      when 503
        app.speaker.speak_up('No daemon running')
        false
      else
        message = response['error'] || "Unable to stop daemon (HTTP #{status_code})"
        app.speaker.speak_up(message)
        false
      end
    end

    def restart
      return :not_running unless ensure_daemon

      flag = restart_requested_flag
      return :already_restarting if flag.true?

      flag.make_true
      Thread.new { stop }
      :scheduled
    rescue StandardError => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding))
      :failed
    end

    def reload
      return unless ensure_daemon

      scheduler_name = @scheduler_name

      if @scheduler
        @scheduler.shutdown
        @scheduler.wait_for_termination
      end
      @scheduler = nil

      settings = SimpleConfigMan.load_settings(app.config_dir, app.config_file, app.config_example)
      app.container.reload_config!(settings)

      @template_cache = nil
      @queue_limits = Concurrent::Hash.new
      @last_execution = {}

      start_scheduler(scheduler_name) if scheduler_name
      true
    rescue StandardError => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding))
      start_scheduler(scheduler_name) if scheduler_name && @scheduler.nil?
      false
    end

    def status
      if running?
        print_status(status_snapshot, lock_time: Utils.lock_time_get)
        return
      end

      response = Client.new.status
      status_code = response['status_code']

      case status_code
      when 200
        body = response['body']
        snapshot = build_snapshot_from_hashes(body)
        lock_time = body.is_a?(Hash) ? body['lock_time'] : nil
        print_status(snapshot, lock_time: lock_time)
      when 401, 403
        app.speaker.speak_up('Not authorized to query daemon status')
      when 503
        app.speaker.speak_up('No daemon running')
      else
        message = response['error'] || "Unable to retrieve daemon status (HTTP #{status_code})"
        app.speaker.speak_up(message)
      end
    end

    def status_snapshot
      jobs = sort_jobs_by_queue(job_registry.values.map(&:dup))
      running = []
      finished = []
      queued = []

      jobs.each do |job|
        status = job_attribute(job, :status).to_s
        finished_at = job_attribute(job, :finished_at)

        if status == 'running' && finished_at.nil?
          running << job
        elsif finished_at || FINISHED_STATUSES.include?(status)
          finished << job
        else
          queued << job
        end
      end
      snapshot = {
        jobs: jobs,
        running: running,
        queued: queued,
        finished: finished,
        queues: queue_metrics_for(running: running, queued: queued, finished: finished)
      }
      snapshot.merge!(status_metadata)
      snapshot
    end

    def build_snapshot_from_hashes(payload)
      jobs = sort_jobs_by_queue(extract_jobs_from(payload))
      running = jobs.select { |job| job[:status].to_s == 'running' }
      finished = jobs.select { |job| FINISHED_STATUSES.include?(job[:status].to_s) }
      queued = jobs.reject { |job| running.include?(job) || finished.include?(job) }
      snapshot = {
        jobs: jobs,
        running: running,
        queued: queued,
        finished: finished,
        queues: queue_metrics_for(running: running, queued: queued, finished: finished)
      }
      snapshot.merge!(status_metadata_from_payload(payload))
      snapshot
    end

    def status_metadata
      started_at = daemon_started_at
      now = Time.now.utc
      uptime = started_at ? [now - started_at, 0.0].max : nil
      {
        started_at: started_at,
        uptime_seconds: uptime,
        resources: build_resource_metrics(uptime)
      }
    end

    def status_metadata_from_payload(payload)
      return { started_at: nil, uptime_seconds: nil, resources: {} } unless payload.is_a?(Hash)

      started_at = payload['started_at'] || payload[:started_at]
      uptime = payload['uptime_seconds'] || payload[:uptime_seconds]
      resources = payload['resources'] || payload[:resources]

      {
        started_at: coerce_time(started_at),
        uptime_seconds: uptime,
        resources: stringify_resource_keys(resources)
      }
    end

    def stringify_resource_keys(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, metric), memo|
        memo[key.to_s] = metric
      end
    end

    def build_resource_metrics(uptime_seconds)
      cpu_time = process_cpu_time
      cpu_percent =
        if uptime_seconds.nil?
          nil
        elsif uptime_seconds.positive?
          (cpu_time / uptime_seconds) * 100.0
        else
          0.0
        end
      {
        'cpu_time_seconds' => cpu_time,
        'cpu_percent' => cpu_percent,
        'rss_mb' => process_memory.mb
      }
    end

    def daemon_started_at
      @daemon_started_at
    end

    def process_cpu_time
      Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    rescue Errno::EINVAL
      0.0
    end

    def process_memory
      @process_memory ||= GetProcessMem.new
    end

    def coerce_time(value)
      case value
      when String
        Time.parse(value)
      when Time
        value
      else
        nil
      end
    rescue ArgumentError
      nil
    end

    def extract_jobs_from(body)
      jobs =
        case body
        when Hash
          Array(body['jobs'])
        when Array
          body
        else
          []
        end

      jobs.map do |job|
        {
          id: job['id'],
          queue: job['queue'],
          status: job['status'] || job[:status],
          task: job['task'] || job[:task],
          created_at: job['created_at'] || job[:created_at],
          started_at: job['started_at'] || job[:started_at],
          finished_at: job['finished_at'] || job[:finished_at],
          result: job['result'] || job[:result],
          error: job['error'] || job[:error],
          children: job['children'] || job[:children],
          children_ids: Array(job['children_ids'] || job[:children_ids]),
          parent_id: job['parent_id'] || job[:parent_id]
        }
      end
    end

    def print_status(snapshot, lock_time: nil)
      jobs = Array(snapshot[:jobs])
      running = Array(snapshot[:running])
      queued = Array(snapshot[:queued])
      finished = Array(snapshot[:finished])
      queues = Array(snapshot[:queues])

      app.speaker.speak_up "Total jobs: #{jobs.count}"
      app.speaker.speak_up "Running jobs: #{running.count}"
      app.speaker.speak_up "Queued jobs: #{queued.count}"
      app.speaker.speak_up "Finished jobs: #{finished.count}"

      unless queues.empty?
        summary = queues.map do |entry|
          queue_name = entry['queue'] || entry[:queue] || ''
          display = queue_name.to_s.empty? ? 'default' : queue_name
          running_count = entry['running'] || entry[:running] || 0
          queued_count = entry['queued'] || entry[:queued] || 0
          finished_count = entry['finished'] || entry[:finished] || 0
          "#{display} r:#{running_count} q:#{queued_count} f:#{finished_count}"
        end
        app.speaker.speak_up "Queues: #{summary.join(' | ')}"
      end

      app.speaker.speak_up LINE_SEPARATOR

      running.each do |job|
        job_id = job_attribute(job, :id)
        queue_name = job_attribute(job, :queue) || 'default'
        status = job_attribute(job, :status)
        parent_id = job_attribute(job, :parent_job_id) || job_attribute(job, :parent_id)
        children_ids =
          if job.respond_to?(:id)
            Array(job_children[job.id])
          else
            Array(job_attribute(job, :children_ids))
          end
        child_count = if children_ids.any?
                         children_ids.length
                       else
                         value = job_attribute(job, :children)
                         value ? value.to_i : 0
                       end
        details = []
        details << "children=#{child_count}" if child_count.positive?
        details << "parent=#{parent_id}" if parent_id
        suffix = details.empty? ? '' : " (#{details.join(', ')})"
        app.speaker.speak_up "- Job #{job_id} (queue: #{queue_name}) status=#{status}#{suffix}"
      end

      app.speaker.speak_up LINE_SEPARATOR
      lock_output = lock_time || Utils.lock_time_get
      app.speaker.speak_up "Global lock time:#{lock_output}"
      app.speaker.speak_up LINE_SEPARATOR
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

        waited = false
        children.each do |child_id|
          future = job_registry[child_id]&.future
          next unless future

          future.wait(0.05)
          waited = true
        end
        next if waited

        Thread.pass
        sleep(0.05)
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

    def enqueue(args:, queue: nil, task: nil, internal: 0, client: Thread.current[:current_daemon], child: 0, env_flags: nil, parent_thread: Thread.current, capture_output: false, wait_for_capacity: true, &block)
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
        block: block,
        capture_output: capture_output
      )
      register_job(job)
      start_job(job, wait_for_capacity: wait_for_capacity)
      job
    end

    def schedule(scheduler)
      return unless running?

      @template_cache ||= app.args_dispatch.load_template(scheduler, app.template_dir)
      %w[periodic continuous].each do |type|
        next unless @template_cache[type]

        @template_cache[type].each do |task, params|
          limit = determine_queue_limit(params)
          queue_limits[task] = limit
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

            queue_name = fetch_function_config(args)[1] || task
            queue_limits[queue_name] = limit
            enqueue(
              args: args,
              queue: queue_name,
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

    def serialize_job(job)
      data = job.to_h
      children_ids = Array(job_children[job.id])
      data['children'] = children_ids.length if children_ids.any?
      data['children_ids'] = children_ids if children_ids.any?
      data['parent_id'] = job.parent_job_id if job.parent_job_id
      data
    end

    def sort_jobs_by_queue(collection)
      collection.sort_by do |job|
        queue = job_attribute(job, :queue).to_s
        created = job_attribute(job, :created_at)
        created_key =
          case created
          when Time
            created.iso8601(6)
          else
            created.to_s
          end
        parent_present = job_attribute(job, :parent_job_id) || job_attribute(job, :parent_id)
        identifier = job_attribute(job, :id).to_s
        [queue, created_key, parent_present ? 1 : 0, identifier]
      end
    end

    def queue_metrics_for(running:, queued:, finished:)
      metrics = Hash.new do |hash, key|
        hash[key] = { 'queue' => key, 'running' => 0, 'queued' => 0, 'finished' => 0, 'total' => 0 }
      end

      { 'running' => running, 'queued' => queued, 'finished' => finished }.each do |key, jobs|
        jobs.each do |job|
          queue = job_attribute(job, :queue).to_s
          entry = metrics[queue]
          entry[key] += 1
          entry['total'] += 1
        end
      end

      metrics.values.sort_by { |entry| entry['queue'] }
    end

    def job_attribute(job, name)
      if job.respond_to?(name)
        job.public_send(name)
      elsif job.is_a?(Hash)
        job[name] || job[name.to_s]
      elsif job.respond_to?(:members) && job.members.include?(name.to_sym)
        job[name]
      elsif job.respond_to?(:[])
        job[name]
      end
    rescue NameError
      nil
    end

    def boot_framework_state
      @running = Concurrent::AtomicBoolean.new(true)
      @stop_event = Concurrent::Event.new
      @last_execution = {}
      @last_email_report = {}
      @template_cache = nil
      @queue_limits = Concurrent::Hash.new
      @jobs = Concurrent::Hash.new
      @job_children = Concurrent::Hash.new { |h, k| h[k] = Concurrent::Array.new }
      # Retain queue_slots for configuration compatibility; the queue is now unbounded.
      @executor = Concurrent::ThreadPoolExecutor.new(
        min_threads: 1,
        max_threads: [app.workers_pool_size.to_i, 1].max,
        fallback_policy: :abort
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

    def start_job(job, wait_for_capacity:)
      future = obtain_future(job, wait_for_capacity: wait_for_capacity)
      case future
      when INLINE_EXECUTED
        return job
      when nil
        unregister_child(job)
        @jobs.delete(job.id)
        return job
      end

      job.future = future
      job.future.on_fulfillment! do |value|
        finalize_job(job, value, nil)
      end
      job.future.on_rejection! do |reason|
        finalize_job(job, nil, reason)
      end
      job
    rescue Concurrent::RejectedExecutionError
      unregister_child(job)
      @jobs.delete(job.id)
      raise
    end

    def obtain_future(job, wait_for_capacity:)
      if inline_child_job?(job)
        execute_inline(job)
        return INLINE_EXECUTED
      end

      loop do
        return Concurrent::Promises.future_on(@executor) { execute_job(job) }
      rescue Concurrent::RejectedExecutionError
        raise unless wait_for_capacity && running?

        wait_for_executor_capacity
      end
    end

    def inline_child_job?(job)
      return false unless job.child.to_i.positive?

      parent_thread = job.parent_thread
      parent_thread&.equal?(Thread.current) && executor_busy?
    end

    def executor_busy?
      executor = @executor
      return false unless executor

      busy_threads = false
      if executor.respond_to?(:max_length) && executor.respond_to?(:scheduled_task_count) && executor.respond_to?(:completed_task_count)
        max_threads = executor.max_length.to_i
        if max_threads.positive?
          running = executor.scheduled_task_count - executor.completed_task_count
          running -= executor.queue_length.to_i if executor.respond_to?(:queue_length)
          busy_threads = running >= max_threads
        end
      end

      saturated_queue = false
      if executor.respond_to?(:remaining_capacity)
        remaining = executor.remaining_capacity
        saturated_queue = remaining && remaining != Float::INFINITY && remaining <= 0
      end

      busy_threads || saturated_queue
    end

    def execute_inline(job)
      value = nil
      error = nil

      begin
        value = execute_job(job)
      rescue StandardError => e
        error = e
      end

      finalize_job(job, value, error)
    end

    def wait_for_executor_capacity
      return unless @executor

      while running? && executor_saturated?(@executor)
        if @executor.respond_to?(:max_queue)
          max_queue = @executor.max_queue
          break if max_queue.nil? || max_queue.negative?
        end
        sleep(0.05)
      end
    end

    def executor_saturated?(executor)
      max_queue = executor.respond_to?(:max_queue) ? executor.max_queue : nil
      bounded_queue = !max_queue.nil? && max_queue >= 0

      if executor.respond_to?(:remaining_capacity)
        remaining = executor.remaining_capacity
        return false if remaining.nil? || remaining == Float::INFINITY
        return false unless bounded_queue

        remaining <= 0
      elsif bounded_queue && executor.respond_to?(:queue_length)
        executor.queue_length >= max_queue
      else
        false
      end
    end

    def execute_job(job)
      thread = Thread.current
      job.worker_thread = thread
      captured_output = nil

      ThreadState.around(thread) do |snapshot|
        thread[:current_daemon] = job.client || snapshot[:current_daemon]
        thread[:parent] = job.parent_thread unless job.parent_thread.equal?(thread)
        thread[:jid] = job.id
        thread[:queue_name] = job.queue
        thread[:log_msg] = String.new if job.child.to_i.positive?
        thread[:child_job] = job.child.to_i.positive? ? 1 : 0
        thread[:child_job_override] = thread[:child_job]

        captured_output = job.capture_output ? String.new : nil
        thread[:captured_output] = captured_output if captured_output

        LibraryBus.initialize_queue(thread)
        app.args_dispatch.set_env_variables(app.env_flags, job.env_flags || {})
        job.status = :running
        job.started_at = Time.now

        begin
          Librarian.run_command(job.args.dup, job.internal, job.task, &job.block)
        ensure
          job.output = captured_output.dup if captured_output
        end
      end
    ensure
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

    def start_scheduler(scheduler_name)
      @scheduler_name = scheduler_name
      @scheduler = Concurrent::TimerTask.new(execution_interval: 0.2) do
        schedule(scheduler_name)
      end
      @scheduler.execute
    end

    def reload_scheduler
      return false unless ensure_daemon

      scheduler_name = @scheduler_name
      return false unless scheduler_name

      if @scheduler
        @scheduler.shutdown
        @scheduler.wait_for_termination
      end

      @template_cache = nil
      @queue_limits = Concurrent::Hash.new
      @last_execution = {}
      @scheduler = nil
      start_scheduler(scheduler_name)
      true
    rescue StandardError => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding))
      false
    end

    def start_quit_timer
      @quit_timer = Concurrent::TimerTask.new(execution_interval: 1) { quit }
      @quit_timer.execute
    end

    def start_trakt_timer
      return unless defined?(TraktAgent)

      @trakt_timer = Concurrent::TimerTask.new(execution_interval: 3300) do
        TraktAgent.refresh_trakt_token
      rescue StandardError => e
        app.speaker.tell_error(e, 'Trakt refresh failure')
      end
      @trakt_timer.execute
    end

    def start_control_server
      opts = app.api_option || {}
      @api_token = resolve_api_token(opts)
      @auth_config = normalize_auth_config(opts['auth'])
      @session_revocations = Concurrent::Hash.new
      @daemon_started_at = Time.now.utc
      port = opts['listen_port'] || 8888
      address = opts['bind_address'] || '127.0.0.1'

      server_options = {
        Port: port,
        BindAddress: address,
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: []
      }

      @session_cookie_secure = ssl_enabled?(opts)

      if @session_cookie_secure
        begin
          server_options.merge!(build_ssl_server_options(opts, address))
        rescue StandardError => e
          app.speaker.tell_error(e, 'TLS configuration error for control server')
          raise
        end
      end

      @control_server = WEBrick::HTTPServer.new(server_options)

      web_root = File.expand_path('web', __dir__)
      if Dir.exist?(web_root)
        @control_server.mount('/', WEBrick::HTTPServlet::FileHandler, web_root,
                               FancyIndexing: false, DirectoryIndex: ['index.html'])
      end

      @control_server.mount_proc('/session') do |req, res|
        handle_session_request(req, res)
      end

      @control_server.mount_proc('/jobs') do |req, res|
        next unless require_authorization(req, res)

        handle_jobs_request(req, res)
      end

      @control_server.mount_proc('/status') do |req, res|
        next unless require_authorization(req, res)

        snapshot = status_snapshot
        jobs = snapshot[:jobs].map { |job| serialize_job(job) }
        started_at = snapshot[:started_at]
        resources = snapshot[:resources]

        json_response(
          res,
          body: {
            'jobs' => jobs,
            'running' => snapshot[:running].map { |job| serialize_job(job) },
            'queued' => snapshot[:queued].map { |job| serialize_job(job) },
            'finished' => snapshot[:finished].map { |job| serialize_job(job) },
            'queues' => snapshot[:queues],
            'lock_time' => Utils.lock_time_get,
            'started_at' => started_at&.iso8601,
            'uptime_seconds' => snapshot[:uptime_seconds],
            'resources' => resources.is_a?(Hash) ? resources : {}
          }
        )
      end

      @control_server.mount_proc('/stop') do |req, res|
        next unless require_authorization(req, res)

        json_response(res, body: { 'status' => 'stopping' })
        Thread.new { stop }
      end

      @control_server.mount_proc('/restart') do |req, res|
        next unless require_authorization(req, res)

        handle_restart_request(req, res)
      end

      @control_server.mount_proc('/calendar') do |req, res|
        next unless require_authorization(req, res)

        handle_calendar_request(req, res)
      end

      @control_server.mount_proc('/logs') do |req, res|
        next unless require_authorization(req, res)

        handle_logs_request(req, res)
      end

      @control_server.mount_proc('/config') do |req, res|
        next unless require_authorization(req, res)

        handle_config_request(req, res)
      end

      @control_server.mount_proc('/templates') do |req, res|
        next unless require_authorization(req, res)

        handle_directory_request(req, res, '/templates', app.template_dir, template_mutex)
      end

      @control_server.mount_proc('/scheduler') do |req, res|
        next unless require_authorization(req, res)

        handle_scheduler_request(req, res)
      end

      @control_server.mount_proc('/trackers') do |req, res|
        next unless require_authorization(req, res)

        handle_directory_request(
          req,
          res,
          '/trackers',
          app.tracker_dir,
          tracker_mutex,
          after_save: method(:rebuild_tracker_registry)
        )
      end

      @control_server.mount_proc('/config/reload') do |req, res|
        next unless require_authorization(req, res)

        handle_config_reload_request(req, res)
      end

      @control_server.mount_proc('/scheduler/reload') do |req, res|
        next unless require_authorization(req, res)

        handle_scheduler_reload_request(req, res)
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
        wait_for_capacity = truthy?(payload['wait_for_capacity'])

        job = enqueue(
          args: args,
          queue: queue,
          task: task,
          internal: internal,
          child: payload['child'].to_i,
          env_flags: payload['env_flags'],
          parent_thread: nil,
          capture_output: payload.fetch('capture_output', false),
          wait_for_capacity: wait_for_capacity
        )

        if wait && job&.future
          job.future.wait
          job.future.value!
        end

        json_response(res, body: { 'job' => job&.to_h })
      when 'GET'
        return handle_job_not_found(res) unless req.path.start_with?('/jobs/')

        handle_job_lookup(req, res)
      else
        method_not_allowed(res, 'GET, POST')
      end
    rescue Concurrent::RejectedExecutionError
      error_response(res, status: 429, message: 'queue_full')
    rescue StandardError => e
      error_response(res, status: 422, message: e.message)
    end

    def handle_job_lookup(req, res)
      jid = req.path.sub('/jobs/', '')
      job = job_registry[jid]
      if job
        json_response(res, body: job.to_h)
      else
        handle_job_not_found(res)
      end
    end

    def handle_job_not_found(res)
      error_response(res, status: 404, message: 'not_found')
    end

    def parse_payload(req)
      return {} if req.body.nil? || req.body.empty?

      JSON.parse(req.body)
    end

    def handle_calendar_request(req, res)
      return method_not_allowed(res, 'GET') unless req.request_method == 'GET'

      filters = {
        type: req.query['type'],
        genres: normalize_list_param(req.query['genres']),
        imdb_min: req.query['imdb_min'],
        imdb_max: req.query['imdb_max'],
        language: req.query['language'],
        country: req.query['country'],
        downloaded: req.query['downloaded'],
        interest: req.query['interest'],
        sort: req.query['sort'],
        page: req.query['page'],
        per_page: req.query['per_page']
      }

      calendar = Calendar.new(app: app)
      json_response(res, body: calendar.entries(filters))
    rescue StandardError => e
      error_response(res, status: 500, message: e.message)
    end

    def normalize_list_param(value)
      return [] if value.nil?
      return value if value.is_a?(Array)

      value.to_s.split(',').map(&:strip)
    end

    def handle_logs_request(req, res)
      return method_not_allowed(res, 'GET') unless req.request_method == 'GET'

      logs = {}
      log_paths.each do |name, path|
        logs[name] = tail_file(path)
      end

      json_response(res, body: { 'logs' => logs })
    end

    def handle_config_request(req, res)
      handle_file_request(req, res, app.config_file, config_mutex, 'GET, PUT')
    end

    def handle_scheduler_request(req, res)
      path = scheduler_template_path
      return error_response(res, status: 404, message: 'scheduler_not_configured') unless path

      handle_file_request(req, res, path, scheduler_mutex, 'GET, PUT')
    end

    def handle_directory_request(req, res, base_path, directory, mutex, after_save: nil)
      if req.path == base_path
        return method_not_allowed(res, 'GET') unless req.request_method == 'GET'

        files = mutex.synchronize do
          if File.directory?(directory)
            Dir.children(directory).select do |entry|
              entry.end_with?('.yml') && File.file?(File.join(directory, entry))
            end.sort
          else
            []
          end
        end

        return json_response(res, body: { 'files' => files })
      end

      unless req.path.start_with?("#{base_path}/")
        return error_response(res, status: 404, message: 'not_found')
      end

      return method_not_allowed(res, 'GET, PUT') unless %w[GET PUT].include?(req.request_method)

      path = sanitize_yaml_path(req.path, base_path, directory)
      return error_response(res, status: 404, message: 'not_found') unless path

      handle_file_request(req, res, path, mutex, 'GET, PUT', after_save: after_save)
    end

    def handle_file_request(req, res, path, mutex, allowed_methods, after_save: nil)
      case req.request_method
      when 'GET'
        content = mutex.synchronize { File.exist?(path) ? File.read(path) : nil }
        json_response(res, body: { 'content' => content })
      when 'PUT'
        begin
          payload = parse_payload(req)
        rescue JSON::ParserError => e
          return error_response(res, status: 422, message: e.message)
        end

        unless payload.key?('content')
          return error_response(res, status: 422, message: 'missing_content')
        end

        content = payload['content']
        unless content.is_a?(String)
          return error_response(res, status: 422, message: 'invalid_content')
        end

        begin
          validate_yaml(content)
        rescue Psych::SyntaxError => e
          return error_response(res, status: 422, message: e.message)
        end

        mutex.synchronize do
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
        end

        begin
          after_save&.call
        rescue StandardError => e
          return error_response(res, status: 500, message: e.message)
        end

        json_response(res, status: 204)
      else
        method_not_allowed(res, allowed_methods)
      end
    end

    def sanitize_yaml_path(request_path, base_path, directory)
      relative = request_path.sub(%r{^#{Regexp.escape(base_path)}/}, '')
      return if relative.empty?

      begin
        decoded = WEBrick::HTTPUtils.unescape(relative)
      rescue ArgumentError
        return
      end

      return unless decoded.end_with?('.yml')

      basename = File.basename(decoded)
      return unless basename == decoded

      File.join(directory, basename)
    end

    def rebuild_tracker_registry
      application = MediaLibrarian.application if defined?(MediaLibrarian)
      return unless application

      container = application.respond_to?(:container) ? application.container : nil
      return unless container

      return unless container.respond_to?(:build_trackers, true)

      trackers = container.send(:build_trackers)

      if application.respond_to?(:trackers=)
        application.trackers = trackers
      elsif container.respond_to?(:trackers=)
        container.trackers = trackers
      end
    end

    def handle_config_reload_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'

      process_reload_request(res) { reload }
    end

    def handle_scheduler_reload_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'
      return error_response(res, status: 404, message: 'scheduler_not_configured') unless @scheduler_name

      process_reload_request(res) { reload_scheduler }
    end

    def handle_restart_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'

      outcome = restart
      case outcome
      when :scheduled
        json_response(res, status: 202, body: { 'status' => 'restarting' })
      when :already_restarting
        error_response(res, status: 409, message: 'restart_in_progress')
      when :not_running
        error_response(res, status: 503, message: 'not_running')
      else
        error_response(res, status: 500, message: 'restart_failed')
      end
    end

    def process_reload_request(res)
      unless running?
        return error_response(res, status: 503, message: 'not_running')
      end

      outcome = yield
      if outcome
        json_response(res, status: 204)
      else
        error_response(res, status: 500, message: 'reload_failed')
      end
    rescue StandardError => e
      error_response(res, status: 500, message: e.message)
    end

    def restart_requested_flag
      @restart_requested_flag ||= Concurrent::AtomicBoolean.new(false)
    end

    def json_response(res, body: nil, status: 200)
      res.status = status
      if body.nil? || status == 204
        res['Content-Type'] = nil
        res.body = ''
      else
        res['Content-Type'] = CONTROL_CONTENT_TYPE
        res.body = JSON.dump(body)
      end
    end

    def error_response(res, status:, message:)
      json_response(res, body: { 'error' => message }, status: status)
    end

    def method_not_allowed(res, allow)
      res['Allow'] = allow
      error_response(res, status: 405, message: 'method_not_allowed')
    end

    def config_mutex
      @config_mutex ||= Mutex.new
    end

    def scheduler_mutex
      @scheduler_mutex ||= Mutex.new
    end

    def template_mutex
      @template_mutex ||= Mutex.new
    end

    def tracker_mutex
      @tracker_mutex ||= Mutex.new
    end

    def scheduler_template_path
      return unless @scheduler_name

      File.join(app.template_dir, "#{@scheduler_name}.yml")
    end

    def authentication_configured?
      auth_enabled? || !api_token.to_s.empty?
    end

    def auth_enabled?
      config = auth_config
      username = config['username']
      password_hash = config['password_hash']
      username && !username.empty? && password_hash && !password_hash.empty?
    end

    def api_token
      @api_token
    end

    def auth_config
      @auth_config ||= {}
    end

    def require_authorization(req, res)
      return true unless authentication_configured?

      if authenticated_session?(req) || api_token_authorized?(req)
        true
      else
        error_response(res, status: 403, message: 'forbidden')
        false
      end
    end

    def authenticated_session?(req)
      !!session_from_request(req)
    end

    def session_from_request(req)
      session = session_cookie_payload(req)
      return unless session && session_valid?(session)

      session
    end

    def api_token_authorized?(req)
      token = api_token
      return false if token.to_s.empty?

      provided = req['X-Control-Token']
      provided = req.query['token'] if (!provided || provided.empty?) && req.respond_to?(:query)
      if (!provided || provided.empty?) && req.body && !req.body.empty?
        begin
          parsed = JSON.parse(req.body)
          provided = parsed['token'] if parsed.is_a?(Hash)
        rescue JSON::ParserError
          provided = nil
        end
      end

      provided == token
    end

    def handle_session_request(req, res)
      case req.request_method
      when 'POST'
        handle_session_create(req, res)
      when 'DELETE'
        handle_session_destroy(req, res)
      when 'GET'
        handle_session_show(req, res)
      else
        method_not_allowed(res, 'GET, POST, DELETE')
      end
    end

    def handle_session_create(req, res)
      unless auth_enabled?
        return error_response(res, status: 503, message: 'auth_not_configured')
      end

      begin
        payload = parse_payload(req)
      rescue JSON::ParserError => e
        return error_response(res, status: 422, message: e.message)
      end

      username = payload['username'].to_s
      password = payload['password'].to_s
      if username.empty? || password.empty?
        return error_response(res, status: 422, message: 'missing_credentials')
      end

      unless username == auth_config['username']
        return error_response(res, status: 401, message: 'invalid_credentials')
      end

      begin
        digest = BCrypt::Password.new(auth_config['password_hash'])
      rescue BCrypt::Errors::InvalidHash => e
        return error_response(res, status: 500, message: e.message)
      end

      unless digest == password
        return error_response(res, status: 401, message: 'invalid_credentials')
      end

      payload = build_session_payload(auth_config['username'])
      unless payload
        return error_response(res, status: 500, message: 'session_unavailable')
      end
      res.cookies << build_session_cookie(payload)
      json_response(res, status: 201, body: { 'username' => auth_config['username'] })
    end

    def handle_session_destroy(req, res)
      session = session_cookie_payload(req)
      revoke_session(session) if session
      res.cookies << expire_session_cookie
      json_response(res, status: 204)
    end

    def handle_session_show(req, res)
      unless auth_enabled?
        return error_response(res, status: 503, message: 'auth_not_configured')
      end

      session = session_from_request(req)
      unless session
        return error_response(res, status: 403, message: 'forbidden')
      end

      json_response(res, body: { 'username' => session['username'] })
    end

    def build_session_cookie(value)
      cookie = WEBrick::Cookie.new(SESSION_COOKIE_NAME, value.to_s)
      cookie.path = '/'
      cookie.secure = !!@session_cookie_secure
      cookie.instance_variable_set(:@httponly, true)
      cookie
    end

    def expire_session_cookie
      cookie = build_session_cookie('')
      cookie.expires = Time.at(0)
      cookie
    end

    def normalize_auth_config(raw)
      return {} unless raw.is_a?(Hash)

      username = raw['username'] || raw[:username]
      password_hash = raw['password_hash'] || raw[:password_hash]

      result = {}
      result['username'] = username.to_s unless username.nil? || username.to_s.empty?
      result['password_hash'] = password_hash.to_s unless password_hash.nil? || password_hash.to_s.empty?
      result
    end

    def build_session_payload(username)
      secret = session_secret
      return unless secret

      data = {
        'username' => username.to_s,
        'issued_at' => Time.now.utc.iso8601
      }
      encode_session_data(data, secret)
    end

    def session_cookie_payload(req)
      cookie = req.cookies.find { |c| c.name == SESSION_COOKIE_NAME }
      return unless cookie && !cookie.value.to_s.empty?

      decode_session_cookie(cookie.value)
    end

    def decode_session_cookie(value)
      secret = session_secret
      return unless secret

      encoded, signature = value.to_s.split('.', 2)
      return unless encoded && signature

      expected = OpenSSL::HMAC.hexdigest('SHA256', secret, encoded)
      return unless secure_compare(signature, expected)

      decoded = Base64.urlsafe_decode64(encoded)
      payload = JSON.parse(decoded)
      payload if payload.is_a?(Hash)
    rescue ArgumentError, JSON::ParserError
      nil
    end

    def session_valid?(session)
      return false unless session.is_a?(Hash)

      username = session['username'].to_s
      issued_at = parse_session_time(session['issued_at'])
      return false if username.empty? || issued_at.nil?

      revoked_at = session_revocations[username]
      return false if revoked_at && issued_at <= revoked_at

      true
    end

    def revoke_session(session)
      return unless session.is_a?(Hash)

      username = session['username'].to_s
      return if username.empty?

      now = Time.now.utc
      previous = session_revocations[username]
      session_revocations[username] = previous && previous > now ? previous : now
    end

    def session_revocations
      @session_revocations ||= Concurrent::Hash.new
    end

    def parse_session_time(value)
      return if value.nil?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def encode_session_data(data, secret)
      encoded = Base64.urlsafe_encode64(JSON.dump(data), padding: false)
      signature = OpenSSL::HMAC.hexdigest('SHA256', secret, encoded)
      "#{encoded}.#{signature}"
    end

    def session_secret
      hash = auth_config['password_hash']
      return if hash.nil? || hash.to_s.empty?

      hash.to_s
    end

    def secure_compare(a, b)
      return false unless a && b

      a = a.to_s
      b = b.to_s
      return false unless a.bytesize == b.bytesize

      result = 0
      a.bytes.zip(b.bytes) { |x, y| result |= x ^ y }
      result.zero?
    end

    def resolve_api_token(opts)
      return nil unless opts

      select_token(
        opts['api_token'],
        opts[:api_token],
        opts['control_token'],
        opts[:control_token],
        ENV['MEDIA_LIBRARIAN_API_TOKEN'],
        ENV['MEDIA_LIBRARIAN_CONTROL_TOKEN']
      )
    end

    def select_token(*candidates)
      candidates.each do |candidate|
        value = normalize_token(candidate)
        return value if value
      end
      nil
    end

    def normalize_token(candidate)
      case candidate
      when nil
        nil
      when String
        token = candidate.strip
        token.empty? ? nil : token
      else
        candidate
      end
    end

    def ssl_enabled?(opts)
      value = opts && (opts['ssl_enabled'] || opts[:ssl_enabled])
      truthy?(value)
    end

    def build_ssl_server_options(opts, address)
      certificate, private_key = load_tls_credentials(opts, address)
      ca_options = resolve_ssl_ca_options(opts)
      client_verify_mode = resolve_ssl_client_verify_mode(opts)
      options_mask = default_ssl_options_mask

      ssl_options = {
        SSLEnable: true,
        SSLPrivateKey: private_key,
        SSLCertificate: certificate,
        SSLVerifyClient: client_verify_mode,
        SSLStartImmediately: true
      }

      ssl_options[:SSLOptions] = options_mask unless options_mask.zero?
      ssl_options.merge!(ca_options) if ca_options
      ssl_options
    end

    def resolve_ssl_ca_options(opts)
      return unless opts

      ca_path = opts['ssl_ca_path'] || opts[:ssl_ca_path]
      return if ca_path.nil? || ca_path.to_s.empty?

      if File.directory?(ca_path)
        { SSLCACertificatePath: ca_path }
      elsif File.file?(ca_path)
        { SSLCACertificateFile: ca_path }
      else
        raise ArgumentError, "Invalid ssl_ca_path: #{ca_path}"
      end
    end

    def resolve_ssl_client_verify_mode(opts)
      return OpenSSL::SSL::VERIFY_NONE unless opts

      mode = opts['ssl_client_verify_mode'] || opts[:ssl_client_verify_mode]
      return OpenSSL::SSL::VERIFY_NONE if mode.nil? || mode.to_s.empty?

      resolve_ssl_verify_mode(mode)
    end

    def resolve_ssl_verify_mode(mode)
      return mode if mode.is_a?(Integer)

      case mode.to_s.downcase
      when '', 'none', 'off', 'false'
        OpenSSL::SSL::VERIFY_NONE
      when 'peer'
        OpenSSL::SSL::VERIFY_PEER
      when 'client_once'
        OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_CLIENT_ONCE
      when 'fail_if_no_peer_cert', 'force_peer', 'require'
        OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
      else
        OpenSSL::SSL::VERIFY_NONE
      end
    end

    def load_tls_credentials(opts, address)
      cert_path = opts['ssl_certificate_path'] || opts[:ssl_certificate_path]
      key_path = opts['ssl_private_key_path'] || opts[:ssl_private_key_path]

      if cert_path.to_s.empty? && key_path.to_s.empty?
        generate_self_signed_certificate(address)
      elsif cert_path.to_s.empty? || key_path.to_s.empty?
        raise ArgumentError, 'TLS requires both ssl_certificate_path and ssl_private_key_path'
      else
        certificate = OpenSSL::X509::Certificate.new(File.binread(cert_path))
        private_key = OpenSSL::PKey.read(File.binread(key_path))
        [certificate, private_key]
      end
    rescue Errno::ENOENT => e
      raise ArgumentError, "Unable to load TLS credentials: #{e.message}"
    rescue OpenSSL::PKey::PKeyError, OpenSSL::X509::CertificateError => e
      raise ArgumentError, "Invalid TLS credentials: #{e.message}"
    end

    def generate_self_signed_certificate(address)
      key = OpenSSL::PKey::RSA.new(2048)
      common_name = address.to_s.empty? ? 'MediaLibrarian' : address.to_s
      subject = OpenSSL::X509::Name.new([['CN', common_name]])
      certificate = OpenSSL::X509::Certificate.new
      certificate.version = 2
      certificate.serial = SecureRandom.random_number(1 << 64)
      certificate.subject = subject
      certificate.issuer = subject
      certificate.public_key = key.public_key
      certificate.not_before = Time.now - 60
      certificate.not_after = Time.now + 365 * 24 * 60 * 60

      extension_factory = OpenSSL::X509::ExtensionFactory.new
      extension_factory.subject_certificate = certificate
      extension_factory.issuer_certificate = certificate
      certificate.add_extension(extension_factory.create_extension('basicConstraints', 'CA:FALSE', true))
      certificate.add_extension(extension_factory.create_extension('keyUsage', 'keyEncipherment,dataEncipherment,digitalSignature', true))
      certificate.add_extension(extension_factory.create_extension('extendedKeyUsage', 'serverAuth', false))

      alt_names = build_subject_alt_names(address)
      certificate.add_extension(extension_factory.create_extension('subjectAltName', alt_names.join(','))) unless alt_names.empty?

      certificate.sign(key, OpenSSL::Digest::SHA256.new)

      app.speaker.speak_up('Génération d\'un certificat TLS auto-signé pour le serveur de contrôle.') if app&.speaker

      [certificate, key]
    end

    def build_subject_alt_names(address)
      names = ['DNS:localhost']
      names << 'IP:127.0.0.1'
      return names unless address && !address.to_s.empty?

      value = address.to_s
      if ip_address?(value)
        names << "IP:#{value}"
      else
        names << "DNS:#{value}"
      end
      names.uniq
    end

    def ip_address?(value)
      IPAddr.new(value)
      true
    rescue IPAddr::InvalidAddressError
      false
    end

    def default_ssl_options_mask
      mask = 0
      mask |= OpenSSL::SSL::OP_NO_SSLv2 if defined?(OpenSSL::SSL::OP_NO_SSLv2)
      mask |= OpenSSL::SSL::OP_NO_SSLv3 if defined?(OpenSSL::SSL::OP_NO_SSLv3)
      mask |= OpenSSL::SSL::OP_NO_COMPRESSION if defined?(OpenSSL::SSL::OP_NO_COMPRESSION)
      mask
    end

    def truthy?(value)
      case value
      when true then true
      when false, nil then false
      when String then value.match?(/\A(true|1|yes|on)\z/i)
      when Numeric then !value.zero?
      else
        !!value
      end
    end

    def log_paths
      log_dir = File.join(app.config_dir, 'log')
      {
        'medialibrarian.log' => File.join(log_dir, 'medialibrarian.log'),
        'medialibrarian_errors.log' => File.join(log_dir, 'medialibrarian_errors.log')
      }
    end

    def tail_file(path, max_lines: LOG_TAIL_LINES)
      return nil unless File.exist?(path)

      buffer = Array.new(max_lines)
      line_count = 0

      File.foreach(path) do |line|
        buffer[line_count % max_lines] = line
        line_count += 1
      end

      return '' if line_count.zero?

      if line_count < max_lines
        buffer.first(line_count).join
      else
        start = line_count % max_lines
        tail = (buffer[start, max_lines - start] || []) + buffer[0, start]
        tail.join
      end
    end

    def validate_yaml(content)
      YAML.safe_load(content, aliases: true)
    end

    def queue_busy?(queue)
      return false if queue.to_s.empty?

      active_jobs_for_queue(queue).size >= queue_limit(queue)
    end

    def active_jobs_for_queue(queue)
      return [] if queue.to_s.empty?

      job_registry.values.select { |job| job.queue == queue && job.running? }
    end

    def queue_limit(queue)
      return 1 if queue.to_s.empty?

      limit = queue_limits[queue]
      unless limit
        limit = queue_limit_from_template(queue)
        limit = 1 if limit.nil? || limit <= 0
        queue_limits[queue] = limit
      end
      limit
    end

    def queue_limit_from_template(queue)
      return unless @template_cache

      %w[continuous periodic].each do |type|
        params = @template_cache[type] && @template_cache[type][queue]
        next unless params

        return determine_queue_limit(params)
      end

      nil
    end

    def queue_limits
      @queue_limits ||= Concurrent::Hash.new
    end

    def determine_queue_limit(params)
      limit = extract_configured_limit(params)
      limit = 1 if limit.nil? || limit <= 0
      limit
    end

    def extract_configured_limit(params)
      return unless params.is_a?(Hash)

      limit = params['max_concurrency'] || params['max_pool_size']
      limit = limit.to_i if limit
      return limit if limit && limit.positive?

      command = params['command']
      return unless command

      config = fetch_function_config(command.split('.'))
      limit = config[0]
      limit = limit.to_i if limit
      limit if limit && limit.positive?
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

      begin
        [@scheduler, @quit_timer, @trakt_timer].compact.each do |timer|
          timer.shutdown
          timer.wait_for_termination
        end

        @control_server&.shutdown
        if @control_thread && @control_thread.alive? && @control_thread != Thread.current
          @control_thread.join
        end

        if @executor
          @executor.shutdown
          @executor.wait_for_termination
        end
      rescue StandardError => e
        app.speaker.tell_error(e, Utils.arguments_dump(binding))
      ensure
        @stop_event&.set
      end
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
      @queue_limits = nil
      @running = nil
      @stop_event = nil
      @is_daemon = false
      @scheduler_name = nil
      @session_cookie_secure = nil
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

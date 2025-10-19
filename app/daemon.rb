# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'time'
require 'webrick'
require 'concurrent-ruby'
require 'bcrypt'
require 'yaml'
require 'fileutils'

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
  LOG_TAIL_BYTES = 4096
  SESSION_COOKIE_NAME = 'ml_session'

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

    def boot_framework_state
      @running = Concurrent::AtomicBoolean.new(true)
      @stop_event = Concurrent::Event.new
      @last_execution = {}
      @last_email_report = {}
      @template_cache = nil
      @queue_limits = Concurrent::Hash.new
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

      @trakt_timer = Concurrent::TimerTask.new(execution_interval: 3700) do
        TraktAgent.get_trakt_token
      rescue StandardError => e
        app.speaker.tell_error(e, 'Trakt refresh failure')
      end
      @trakt_timer.execute
    end

    def start_control_server
      opts = app.api_option || {}
      @api_token = resolve_api_token(opts)
      @auth_config = normalize_auth_config(opts['auth'])
      @session_store = Concurrent::Hash.new

      port = opts['listen_port'] || 8888
      address = opts['bind_address'] || '127.0.0.1'

      @control_server = WEBrick::HTTPServer.new(
        Port: port,
        BindAddress: address,
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: []
      )

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

        json_response(res, body: status_snapshot[:jobs].map(&:to_h))
      end

      @control_server.mount_proc('/stop') do |req, res|
        next unless require_authorization(req, res)

        json_response(res, body: { 'status' => 'stopping' })
        Thread.new { stop }
      end

      @control_server.mount_proc('/logs') do |req, res|
        next unless require_authorization(req, res)

        handle_logs_request(req, res)
      end

      @control_server.mount_proc('/config') do |req, res|
        next unless require_authorization(req, res)

        handle_config_request(req, res)
      end

      @control_server.mount_proc('/scheduler') do |req, res|
        next unless require_authorization(req, res)

        handle_scheduler_request(req, res)
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

        json_response(res, body: { 'job' => job&.to_h })
      when 'GET'
        return handle_job_not_found(res) unless req.path.start_with?('/jobs/')

        handle_job_lookup(req, res)
      else
        method_not_allowed(res, 'GET, POST')
      end
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

    def handle_file_request(req, res, path, mutex, allowed_methods)
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

        json_response(res, status: 204)
      else
        method_not_allowed(res, allowed_methods)
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

    def session_store
      @session_store ||= Concurrent::Hash.new
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
      session_id, session = session_from_request(req)
      session_id && session
    end

    def session_from_request(req)
      cookie = req.cookies.find { |c| c.name == SESSION_COOKIE_NAME }
      return unless cookie && !cookie.value.to_s.empty?

      session = session_store[cookie.value]
      return unless session

      [cookie.value, session]
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
      else
        method_not_allowed(res, 'POST, DELETE')
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

      session_id = SecureRandom.hex(32)
      session_store[session_id] = {
        'username' => auth_config['username'],
        'created_at' => Time.now
      }

      res.cookies << build_session_cookie(session_id)
      json_response(res, status: 201, body: { 'username' => auth_config['username'] })
    end

    def handle_session_destroy(req, res)
      session_id, = session_from_request(req)
      unless session_id
        return error_response(res, status: 403, message: 'forbidden')
      end

      session_store.delete(session_id)
      res.cookies << expire_session_cookie
      json_response(res, status: 204)
    end

    def build_session_cookie(value)
      cookie = WEBrick::Cookie.new(SESSION_COOKIE_NAME, value.to_s)
      cookie.path = '/'
      cookie.secure = true
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

    def resolve_api_token(opts)
      return nil unless opts

      opts['api_token'] || opts[:api_token] ||
        opts['control_token'] || opts[:control_token] ||
        ENV['MEDIA_LIBRARIAN_API_TOKEN'] || ENV['MEDIA_LIBRARIAN_CONTROL_TOKEN']
    end

    def log_paths
      log_dir = File.join(app.config_dir, 'log')
      {
        'medialibrarian.log' => File.join(log_dir, 'medialibrarian.log'),
        'medialibrarian_errors.log' => File.join(log_dir, 'medialibrarian_errors.log')
      }
    end

    def tail_file(path)
      return nil unless File.exist?(path)

      File.open(path, 'r') do |file|
        size = file.size
        if size > LOG_TAIL_BYTES
          file.seek(-LOG_TAIL_BYTES, IO::SEEK_END)
          file.gets
        else
          file.seek(0, IO::SEEK_SET)
        end
        file.read
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
      @queue_limits = nil
      @running = nil
      @stop_event = nil
      @is_daemon = false
      @scheduler_name = nil
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

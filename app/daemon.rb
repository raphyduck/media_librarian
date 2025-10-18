require 'securerandom'
require 'sidekiq'
require 'sidekiq/api'
require 'sidekiq/cli'

class Daemon
  DEFAULT_QUEUE = 'default'.freeze
  QUEUE_LIMITS_KEY = 'media_librarian:queue_limits'.freeze
  JOB_MAPPING_KEY = 'media_librarian:job_mapping'.freeze
  STATUS_SAMPLE_LIMIT = 10

  class << self
    def ensure_daemon
      return true if is_daemon?
      $speaker.speak_up 'No daemon running'
      false
    end

    def is_daemon?
      return false unless File.exist?($pidfile)
      pid = ::File.read($pidfile).to_i
      return false if pid.zero?
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::ENOENT
      false
    end

    def start(scheduler: 'scheduler')
      return $speaker.speak_up 'Daemon already started' if is_daemon?

      $speaker.speak_up('Will now work in the background')
      $librarian.daemonize
      $librarian.write_pid
      Logger.renew_logs($config_dir + '/log')

      boot_file = File.expand_path('../config/sidekiq_boot.rb', __dir__)
      config_file = File.expand_path('../config/sidekiq.yml', __dir__)
      args = []
      args += ['-r', boot_file] if File.exist?(boot_file)
      args += ['-C', config_file] if File.exist?(config_file)

      cli = Sidekiq::CLI.new
      cli.parse(args)
      cli.run
    rescue => e
      $speaker.tell_error(e, Utils.arguments_dump(binding))
    ensure
      $librarian.delete_pid if File.exist?($pidfile)
      $speaker.speak_up('Shutting down')
    end

    def stop
      return unless ensure_daemon
      pid = ::File.read($pidfile).to_i
      Process.kill('TERM', pid)
      $speaker.speak_up('Stop signal sent')
    rescue => e
      $speaker.tell_error(e, Utils.arguments_dump(binding))
    end

    def reload
      return unless ensure_daemon
      pid = ::File.read($pidfile).to_i
      Process.kill('USR1', pid)
      $speaker.speak_up('Reload signal sent')
    rescue => e
      $speaker.tell_error(e, Utils.arguments_dump(binding))
    end

    def quit
      stop
    end

    def schedule(template_name)
      SchedulerJob.perform_async(template_name)
    end

    def thread_cache_add(queue, args, jid, task, internal = 0, max_pool_size = 0, continuous = 0, _save_to_disk = 0, client = Thread.current[:current_daemon], expiration = 43200, child = 0, &_block)
      return if queue.nil?

      queue_name = normalize_queue(queue, task)
      concurrency = max_pool_size.to_i > 0 ? max_pool_size.to_i : nil
      register_queue_limit(queue_name, concurrency) if concurrency

      payload = {
        'args' => args,
        'jid' => jid,
        'task' => task,
        'queue_name' => queue_name,
        'context' => {
          'internal' => internal,
          'client' => client,
          'child' => child,
          'continuous' => continuous,
          'expiration' => expiration,
          'env_flags' => dump_env_flags(continuous.to_i > 0 ? 0 : expiration)
        },
        'concurrency' => concurrency
      }

      job_jid = CommandJob.set(queue: queue_name).perform_async(payload)
      register_job_mapping(jid, job_jid)
      job_jid
    end

    def register_queue_limit(queue_name, concurrency)
      normalized = normalize_queue(queue_name, queue_name)
      Sidekiq.redis do |conn|
        conn.call('HSET', QUEUE_LIMITS_KEY, normalized, concurrency.to_i)
      end
    end

    def queue_limit(queue_name)
      normalized = normalize_queue(queue_name, queue_name)
      Sidekiq.redis do |conn|
        value = conn.call('HGET', QUEUE_LIMITS_KEY, normalized)
        value&.to_i
      end
    end

    def register_job_mapping(requested_jid, actual_jid)
      return if requested_jid.to_s.empty? || actual_jid.to_s.empty?

      Sidekiq.redis do |conn|
        conn.call('HSET', JOB_MAPPING_KEY, requested_jid, actual_jid)
      end
    end

    def remove_job_mapping(requested_jid)
      return if requested_jid.to_s.empty?

      Sidekiq.redis do |conn|
        conn.call('HDEL', JOB_MAPPING_KEY, requested_jid)
      end
    end

    def resolve_job_jid(jid)
      Sidekiq.redis do |conn|
        conn.call('HGET', JOB_MAPPING_KEY, jid) || jid
      end
    end

    def remove_job_mapping_by_actual(actual_jid)
      actual = actual_jid.to_s
      return if actual.empty?

      Sidekiq.redis do |conn|
        entries = conn.call('HGETALL', JOB_MAPPING_KEY)
        next if entries.nil? || entries.empty?

        entries.each_slice(2) do |requested, stored|
          next unless stored == actual
          conn.call('HDEL', JOB_MAPPING_KEY, requested)
        end
      end
    end

    def clear_job_mappings
      Sidekiq.redis do |conn|
        conn.call('DEL', JOB_MAPPING_KEY)
      end
    end

    def normalize_queue(queue, task)
      candidate = (queue || task || DEFAULT_QUEUE).to_s.strip
      candidate = DEFAULT_QUEUE if candidate.empty?
      candidate.downcase.gsub(/[^a-z0-9_]+/, '_')
    end

    def clear_waiting_worker(*); end

    def clear_workers; end

    def get_children_count(_qname)
      0
    end

    def queue_busy?(queue_name)
      active_jobs_for_queue(queue_name).any?
    end

    def merge_notifications(t, parent = Thread.current)
      Utils.lock_time_merge(t, parent)
      return if parent[:email_msg].nil?
      $speaker.speak_up(t[:log_msg].to_s, -1, parent) if t[:log_msg]
      parent[:email_msg] << t[:email_msg].to_s
      parent[:send_email] = t[:send_email].to_i if t[:send_email].to_i > 0
    end

    def consolidate_children(thread = Thread.current)
      thread[:waiting_for] = 1
      wait_for_children(thread)
      thread[:waiting_for] = nil
      LibraryBus.merge_queue(thread)
    end

    def wait_for_children(_thread); end

    def kill(jid:)
      return clear_all_jobs if jid.to_s == 'all'

      requested = jid.to_s
      target_jid = resolve_job_jid(requested)
      removed = delete_from_queues(target_jid) || delete_from_set(Sidekiq::ScheduledSet.new, target_jid) || delete_from_set(Sidekiq::RetrySet.new, target_jid)
      if removed
        remove_job_mapping(requested)
        remove_job_mapping_by_actual(target_jid)
        $speaker.speak_up("Killed job '#{requested}'")
        1
      else
        $speaker.speak_up("No job found with ID '#{requested}'!")
        0
      end
    end

    def delete_from_queues(jid)
      Sidekiq::Queue.all.each do |queue|
        job = queue.find { |j| j.jid.to_s == jid.to_s }
        next unless job
        job.delete
        return true
      end
      false
    end

    def delete_from_set(set, jid)
      job = set.find { |j| j.jid.to_s == jid.to_s }
      return false unless job
      job.delete
      true
    end

    def clear_all_jobs
      Sidekiq::Queue.all.each(&:clear)
      Sidekiq::ScheduledSet.new.clear
      Sidekiq::RetrySet.new.clear
      clear_job_mappings
      $speaker.speak_up('Cleared all pending jobs')
      1
    end

    def status
      return unless ensure_daemon

      stats = Sidekiq::Stats.new
      $speaker.speak_up "Processed: #{stats.processed}"
      $speaker.speak_up "Failed: #{stats.failed}"
      $speaker.speak_up LINE_SEPARATOR

      Sidekiq::Queue.all.each do |queue|
        describe_queue(queue)
      end

      describe_scheduled_jobs
      describe_retry_jobs
      describe_bus_state
    end

    def job_id
      SecureRandom.uuid
    end

    def dump_env_flags(expiration = 43200)
      env_flags = {}
      $env_flags.keys.each { |k| env_flags[k.to_s] = Thread.current[k] }
      env_flags['expiration_period'] = expiration
      env_flags
    end

    def fetch_function_config(args, config = $available_actions)
      args = args.dup
      config = config[args.shift.to_sym]
      if config.is_a?(Hash)
        fetch_function_config(args, config)
      else
        return config.dup.drop(2)
      end
    rescue
      []
    end

    private

    def active_jobs_for_queue(queue_name)
      normalized = normalize_queue(queue_name, queue_name)
      Sidekiq::Workers.new.each_with_object([]) do |(_, _, work), jobs|
        jobs << work if work['queue'] == normalized
      end
    end

    def describe_queue(queue)
      queue_name = queue.name
      active_jobs = active_jobs_for_queue(queue_name)
      limit = queue_limit(queue_name)
      message = "Queue #{queue_name}: #{queue.size} enqueued, #{active_jobs.size} running"
      message += " (limit #{limit})" if limit
      $speaker.speak_up(message)

      describe_running_jobs(active_jobs)
      describe_enqueued_jobs(queue)
      $speaker.speak_up(LINE_SEPARATOR)
    end

    def describe_running_jobs(active_jobs)
      return if active_jobs.empty?

      $speaker.speak_up "#{SPACER}Running jobs:"
      active_jobs.take(STATUS_SAMPLE_LIMIT).each do |work|
        $speaker.speak_up(format_running_job(work))
      end

      remaining = active_jobs.length - STATUS_SAMPLE_LIMIT
      return unless remaining.positive?

      $speaker.speak_up "#{SPACER * 2}... and #{remaining} more"
    end

    def describe_enqueued_jobs(queue)
      jobs = queue.take(STATUS_SAMPLE_LIMIT)
      return if jobs.empty?

      $speaker.speak_up "#{SPACER}Queued jobs:"
      jobs.each do |job|
        $speaker.speak_up(format_queue_job(job))
      end

      remaining = queue.size - jobs.length
      return unless remaining.positive?

      $speaker.speak_up "#{SPACER * 2}... and #{remaining} more"
    end

    def describe_scheduled_jobs
      scheduled = Sidekiq::ScheduledSet.new
      total = scheduled.size
      return if total.zero?

      $speaker.speak_up 'Scheduled jobs:'
      scheduled.take(STATUS_SAMPLE_LIMIT).each do |job|
        $speaker.speak_up(format_scheduled_job(job))
      end

      remaining = total - STATUS_SAMPLE_LIMIT
      $speaker.speak_up "#{SPACER}... and #{remaining} more" if remaining.positive?
      $speaker.speak_up(LINE_SEPARATOR)
    end

    def describe_retry_jobs
      retry_set = Sidekiq::RetrySet.new
      total = retry_set.size
      return if total.zero?

      $speaker.speak_up 'Retry jobs:'
      retry_set.take(STATUS_SAMPLE_LIMIT).each do |job|
        $speaker.speak_up(format_retry_job(job))
      end

      remaining = total - STATUS_SAMPLE_LIMIT
      $speaker.speak_up "#{SPACER}... and #{remaining} more" if remaining.positive?
      $speaker.speak_up(LINE_SEPARATOR)
    end

    def describe_bus_state
      bus_vars = BusVariable.list_bus_variables
      unless bus_vars.empty?
        $speaker.speak_up 'Bus Variables:'
        bus_vars.each do |vname|
          v = LibraryBus.bus_variable_get(vname)
          details = "#{SPACER}* Variable '#{vname}': Type '#{v.class}'"
          details += ", with #{v.length} elements" if [Hash, Vash, Array].include?(v.class)
          $speaker.speak_up(details)
        end
        $speaker.speak_up(LINE_SEPARATOR)
      end

      $speaker.speak_up "Global lock time:#{Utils.lock_time_get}"
      $speaker.speak_up(LINE_SEPARATOR)
    end

    def format_running_job(work)
      worker_payload = work['payload'] || {}
      payload = extract_job_payload(worker_payload['args'])
      task = job_task(payload)
      job_jid = work['jid']
      requested = payload['jid']
      started_at = work['run_at'] ? Time.at(work['run_at']) : nil
      duration = started_at ? time_in_words(Time.now - started_at) : nil

      message = "#{SPACER * 2}- Job '#{task}' (jid '#{job_jid}'"
      message += ", requested '#{requested}'" if requested && requested != job_jid
      message += ", queue '#{work['queue']}')"
      message += " running for #{duration}" if duration
      message
    end

    def format_queue_job(job)
      payload = extract_job_payload(job.args)
      task = job_task(payload)
      enqueued_at = job.enqueued_at ? Time.at(job.enqueued_at) : nil
      wait = enqueued_at ? time_in_words(Time.now - enqueued_at) : nil

      message = "#{SPACER * 2}- Job '#{task}' (jid '#{job.jid}', queue '#{job.queue}'"
      if (requested = payload['jid']) && requested != job.jid
        message += ", requested '#{requested}'"
      end
      message += ')'
      message += " enqueued #{wait} ago" if wait
      message
    end

    def format_scheduled_job(job)
      payload = extract_job_payload(job.args)
      task = job_task(payload)
      wait = job.at ? time_in_words(job.at - Time.now) : nil

      message = "#{SPACER * 1}- Job '#{task}' (jid '#{job.jid}', queue '#{job.queue}'"
      if (requested = payload['jid']) && requested != job.jid
        message += ", requested '#{requested}'"
      end
      message += ')'
      message += " scheduled in #{wait}" if wait
      message
    end

    def format_retry_job(job)
      payload = extract_job_payload(job.args)
      task = job_task(payload)
      wait = job.at ? time_in_words(job.at - Time.now) : nil

      message = "#{SPACER * 1}- Job '#{task}' (jid '#{job.jid}', queue '#{job.queue}'"
      if (requested = payload['jid']) && requested != job.jid
        message += ", requested '#{requested}'"
      end
      message += ')'
      message += " retrying in #{wait}" if wait
      message
    end

    def extract_job_payload(args)
      first = Array(args).first
      first.is_a?(Hash) ? first : {}
    end

    def job_task(payload)
      return payload['task'] if payload['task']

      args = Array(payload['args']).map(&:to_s)
      return 'unknown' if args.empty?

      args.join(' ')
    end

    def time_in_words(seconds)
      return nil unless seconds && seconds > 0

      TimeUtils.seconds_in_words(seconds)
    rescue
      nil
    end
  end
end

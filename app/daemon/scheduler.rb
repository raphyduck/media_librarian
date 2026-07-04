# frozen_string_literal: true

# Scheduler support for the daemon: per-queue concurrency limits, scheduler
# task signatures / diffing / obsolete-entry cancellation, calendar-feed
# bootstrap, and periodic-run frequency checks. Reopens Daemon's singleton
# class so these methods stay byte-for-byte identical to their prior inline
# definitions; extracted purely to shrink app/daemon.rb. Zeitwerk is told to
# ignore this file (see Application#setup_loader) because it reopens Daemon
# rather than defining a Daemon::Scheduler constant.

class Daemon
  class << self
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

    def apply_queue_limit(queue_name, args)
      return if queue_name.to_s.empty? || queue_limits.key?(queue_name)

      limit = fetch_function_config(args)[0]
      limit = limit.to_i if limit
      queue_limits[queue_name] = limit if limit && limit.positive?
    end

    def build_task_args(params)
      args = params['command'].to_s.split('.')
      if params['args'].is_a?(Hash)
        args += params['args'].map { |a, v| "--#{a}=#{v}" }
      elsif params['args'].is_a?(Array)
        args += params['args']
      end
      args
    end

    def scheduler_task_signature(task, params, type)
      return unless params.is_a?(Hash)

      args = params['args']
      normalized_args = args.is_a?(Hash) ? args.sort.to_h : args
      frequency = type == 'periodic' ? task_frequency(task, params).to_i : nil
      JSON.generate([type, task.to_s, params['command'].to_s, normalized_args, frequency])
    end

    def scheduler_task_queue(task, params, type)
      return task unless type == 'periodic'

      args = build_task_args(params)
      fetch_function_config(args)[1] || task
    end

    def scheduler_entries_by_task(template)
      entries = {}
      return entries unless template

      %w[periodic continuous].each do |type|
        next unless template[type]

        template[type].each do |task, params|
          entries[[type, task]] = params if params.is_a?(Hash)
        end
      end
      entries
    end

    def normalize_scheduler_args(args)
      args.is_a?(Hash) ? args.sort.to_h : args
    end

    def scheduler_command_args_changed?(old_params, new_params)
      return true unless new_params

      old_params['command'].to_s != new_params['command'].to_s ||
        normalize_scheduler_args(old_params['args']) != normalize_scheduler_args(new_params['args'])
    end

    def obsolete_scheduler_entries(old_template, new_template)
      old_entries = scheduler_entries_by_task(old_template)
      new_entries = scheduler_entries_by_task(new_template)

      old_entries.each_with_object([]) do |((type, task), params), memo|
        new_params = new_entries[[type, task]]
        next unless new_params.nil? || scheduler_command_args_changed?(params, new_params)

        memo << { type: type, task: task, params: params }
      end
    end

    def cancel_scheduler_jobs(entries)
      return if entries.empty?

      entries.each do |entry|
        task = entry[:task]
        type = entry[:type]
        queue = scheduler_task_queue(task, entry[:params], type)

        job_registry.values.each do |job|
          next if job.finished?
          next unless job.task == task && job.queue == queue
          next if type == 'periodic' && job.running?

          cancel_job(job)
        end
      end
    end

    def scheduler_signature_map(template)
      signatures = {}
      return signatures unless template

      %w[periodic continuous].each do |type|
        next unless template[type]

        template[type].each do |task, params|
          signature = scheduler_task_signature(task, params, type)
          next unless signature

          signatures[signature] = {
            task: task,
            queue: scheduler_task_queue(task, params, type)
          }
        end
      end
      signatures
    end

    def task_frequency(_task, params)
      Utils.timeperiod_to_sec(params['every']).to_i
    end

    def bootstrap_calendar_feed_if_needed
      return unless calendar_bootstrap_enabled?
      return unless calendar_entries_empty?

      CalendarFeed.refresh_feed
    rescue StandardError => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding))
    end

    def calendar_bootstrap_enabled?
      config = calendar_config
      return true unless config.is_a?(Hash) && config.key?('refresh_on_start')

      truthy?(config['refresh_on_start'])
    end

    def calendar_entries_empty?
      db = app.respond_to?(:db) ? app.db : nil
      return false unless db && db.respond_to?(:database)
      return false if db.respond_to?(:table_exists?) && !db.table_exists?(:calendar_entries)

      dataset = db.database && db.database.respond_to?(:[]) ? db.database[:calendar_entries] : nil
      return false unless dataset && dataset.respond_to?(:first)

      dataset.first.nil?
    rescue StandardError => e
      app.speaker.tell_error(e, Utils.arguments_dump(binding))
      false
    end

    def calendar_config
      config = app.config if app.respond_to?(:config)
      section = config.is_a?(Hash) ? config['calendar'] : nil
      section.is_a?(Hash) ? section : nil
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
  end
end

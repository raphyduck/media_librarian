require 'sidekiq/api'
require_relative 'application_job'

class SchedulerJob < ApplicationJob
  sidekiq_options queue: 'scheduler', retry: false

  LAST_EXECUTION_KEY = 'media_librarian:scheduler:last_execution'.freeze
  POLL_INTERVAL = 60

  def perform(template_name = 'scheduler')
    jobs = $args_dispatch.load_template(template_name, $template_dir)
    process_periodic(jobs['periodic'] || {})
    process_continuous(jobs['continuous'] || {})
    self.class.enqueue_next(template_name)
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
  end

  def self.enqueue_next(template_name)
    interval = ($config.dig('daemon', 'scheduler_poll_interval') || POLL_INTERVAL).to_i
    interval = POLL_INTERVAL if interval <= 0

    scheduled = Sidekiq::ScheduledSet.new
    existing = scheduled.find do |job|
      job.klass == name && job.args.first == template_name
    end

    if existing && existing.at && existing.at > Time.now
      return existing.jid
    end

    existing&.delete
    perform_in(interval, template_name)
  end

  private

  def process_periodic(tasks)
    tasks.each do |task, params|
      args = build_args(params)
      frequency = Utils.timeperiod_to_sec(params['every']).to_i
      next if frequency <= 0
      last_run = last_execution(task)
      next if last_run && Time.now <= last_run + frequency

      enqueue_command(task, args, params)
      mark_execution(task)
    end
  end

  def process_continuous(tasks)
    tasks.each do |task, params|
      args = build_args(params)
      queue_name, concurrency, _expiration = command_config(args, params, task)
      next if Daemon.queue_busy?(queue_name, concurrency)

      enqueue_command(task, args + ['--continuous=1'], params, continuous: true)
    end
  end

  def build_args(params)
    args = params['command'].to_s.split('.').reject(&:empty?)
    case params['args']
    when Hash
      args + params['args'].map { |a, v| "--#{a}=#{v}" }
    when Array
      args + params['args']
    else
      args
    end
  end

  def enqueue_command(task, args, params, continuous: false)
    queue_name, concurrency, expiration = command_config(args, params, task)

    Daemon.thread_cache_add(queue_name, args, Daemon.job_id, task, 0, concurrency, continuous ? 1 : 0, 0, Thread.current[:current_daemon], expiration)
  end

  def command_config(args, params, task)
    config = Daemon.fetch_function_config(args)
    concurrency = (config[0] || params['max_concurrency'] || 1).to_i
    concurrency = 1 if concurrency <= 0
    queue_name = config[1] || task
    expiration = params['expiration'] || 43_200

    [Daemon.normalize_queue(queue_name, task), concurrency, expiration]
  end

  def last_execution(task)
    Sidekiq.redis do |conn|
      value = conn.call('HGET', LAST_EXECUTION_KEY, task)
      value ? Time.at(value.to_i) : nil
    end
  end

  def mark_execution(task)
    Sidekiq.redis do |conn|
      conn.call('HSET', LAST_EXECUTION_KEY, task, Time.now.to_i)
    end
  end
end

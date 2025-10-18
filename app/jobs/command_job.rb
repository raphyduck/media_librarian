require_relative 'application_job'

class CommandJob < ApplicationJob
  def perform(payload)
    queue_name = payload['queue_name'] || Daemon::DEFAULT_QUEUE
    concurrency = payload['concurrency']
    concurrency = concurrency.to_i if concurrency
    concurrency = nil if concurrency && concurrency <= 0
    args = (payload['args'] || []).dup
    context = payload['context'] || {}
    requested_jid = payload['jid']
    actual_jid = jid
    job_identifier = requested_jid || actual_jid
    task = payload['task'] || args[0..1].join(' ')

    with_concurrency_limit(queue_name, concurrency, actual_jid) do
      execute(args, task, job_identifier, queue_name, context, actual_jid)
    end
  ensure
    Daemon.remove_job_mapping(requested_jid) if requested_jid
    Daemon.remove_job_mapping_by_actual(actual_jid) if actual_jid
  end

  private

  def execute(args, task, jid, queue_name, context, actual_jid)
    env_flags = context['env_flags'] || {}
    $args_dispatch.set_env_variables($env_flags, env_flags)

    thread = Thread.current
    thread[:object] = task
    thread[:jid] = jid
    thread[:sidekiq_jid] = actual_jid
    thread[:queue_name] = queue_name
    thread[:current_daemon] = context['client']
    thread[:child] = context['child']

    LibraryBus.initialize_queue(thread)
    Librarian.run_command(args, context['internal'], task)
  ensure
    $args_dispatch.set_env_variables($env_flags, {})
  end
end

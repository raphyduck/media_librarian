# frozen_string_literal: true

# Executor supervision for the daemon: every SUPERVISOR_INTERVAL_SECONDS it
# finalizes jobs that can no longer finish (past their hard deadline, or with
# no live worker thread), dumps every thread's stack when the pool stalls, and
# rebuilds the worker pool. Reopens Daemon's singleton class; Zeitwerk is told
# to ignore this file (see Application#setup_loader).

class Daemon
  class << self
    def supervise_executor
      return unless running?
      return if restart_requested_flag.true? || force_shutdown_flag.true?
      return if app.librarian&.quit?

      sweep_stuck_jobs
      rebuild_executor('stalled') if executor_stalled?
    rescue StandardError => e
      app.speaker.tell_error(e, 'Daemon.supervise_executor')
    end

    # A running job whose worker thread is gone is only declared orphaned on
    # the second consecutive sweep: between execute_job's ensure and the
    # resolution of the future there is a short window where a healthy job
    # has no worker thread.
    def sweep_stuck_jobs(now = Time.now)
      suspects = []
      job_registry.values.each do |job|
        next unless job.running?

        if job.deadline && now > job.deadline + HARD_TIMEOUT_GRACE_SECONDS
          finalize_job(job, nil, JobTimeout.new('timeout'))
          next
        end

        thread = job.worker_thread
        next if thread&.alive?

        if @orphan_suspects.to_a.include?(job.id)
          finalize_job(job, nil, 'orphaned')
        else
          suspects << job.id
        end
      end
      @orphan_suspects = suspects
    end

    # Stalled means: a job posted to the executor is waiting, nothing has
    # started or finished for the configured delay, and fewer live worker
    # threads are busy than the pool has slots (the signature of lost slots).
    def executor_stalled?(now = Time.now)
      executor = @executor
      return false unless executor

      waiting = job_registry.values.any? do |job|
        job.status == :queued && !job.finished? && job.future && !job.future.resolved?
      end
      return false unless waiting
      return false if now - (@last_job_progress_at || now) < supervisor_stall_seconds

      busy_threads = job_registry.values.select(&:running?).map(&:worker_thread).compact.select(&:alive?).uniq.size
      busy_threads < executor.max_length.to_i
    end

    def rebuild_executor(reason)
      app.speaker.speak_up("[supervisor] executor #{reason}: dumping threads and rebuilding worker pool", 0, Thread.current, 1, 1)
      dump_threads
      old = @executor
      @executor = build_executor
      stranded = job_registry.values.reject(&:finished?)
      old&.kill
      stranded.each do |job|
        if job.status == :queued
          next unless job.future && !job.future.resolved?

          attach_future(job, Concurrent::Promises.future_on(@executor) { execute_job(job) })
        else
          finalize_job(job, nil, 'executor restarted')
        end
      end
      @last_job_progress_at = Time.now
      @orphan_suspects = []
    end

    def dump_threads
      Thread.list.each do |t|
        header = "[supervisor] thread #{t.name || t.object_id} status=#{t.status.inspect} jid=#{t[:jid]} queue=#{t[:queue_name]}"
        app.speaker.speak_up(([header] + Array(t.backtrace).first(40)).join("\n  "), 0, Thread.current, 1, 1)
      end
    end
  end
end

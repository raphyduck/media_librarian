# frozen_string_literal: true

# Job lifecycle for the daemon control server: registration, executor
# scheduling, inline child execution, capacity waits, run, finalize, prune and
# cancel. Reopens Daemon's singleton class so these methods stay byte-for-byte
# identical to their prior inline definitions; extracted purely to shrink
# app/daemon.rb. Zeitwerk is told to ignore this file (see
# Application#setup_loader) because it reopens Daemon rather than defining a
# Daemon::JobExecutor constant.

class Daemon
  class << self
    def register_job(job)
      @jobs[job.id] = job
      parent_thread = job.parent_thread
      parent_jid = parent_thread && parent_thread[:jid]
      return unless parent_jid

      job.parent_job_id = parent_jid
      # Create the array on write now that @job_children has no default proc
      # (so reads elsewhere no longer materialize entries — see Daemon setup).
      (job_children[parent_jid] ||= Concurrent::Array.new) << job.id
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
        unless wait_for_queue_capacity(job.queue, wait_for_capacity: wait_for_capacity)
          raise Concurrent::RejectedExecutionError
        end
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

    def wait_for_queue_capacity(queue, wait_for_capacity:)
      return true if queue.to_s.empty? || !queue_busy?(queue)
      return false unless wait_for_capacity && running?

      while running? && queue_busy?(queue)
        sleep(0.05)
      end
      true
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
      # A job cancelled while still queued was already finalized by cancel_job;
      # the underlying future has no working cancel, so without this guard it
      # would run anyway (re-setting status to :running and doing the work).
      return if job.finished_at || job.status == :cancelled

      thread = Thread.current
      job.worker_thread = thread
      captured_output = nil
      inline_child = job.child.to_i.positive? && job.parent_thread.equal?(thread)

      ThreadState.around(thread) do |snapshot|
        thread[:current_daemon] = job.client || snapshot[:current_daemon]
        thread[:parent] = job.parent_thread unless job.parent_thread.equal?(thread)
        thread[:parent_daemon] = job.parent_daemon
        if inline_child
          parent_jid = thread[:jid]
          thread[:bus_parent_jid] = parent_jid if parent_jid
        end
        thread[:jid] = job.id
        thread[:queue_name] = job.queue
        if job.child.to_i.positive?
          thread[:log_msg] = inline_child ? nil : String.new(encoding: 'UTF-8')
        end
        thread[:child_job] = job.child.to_i.positive? ? 1 : 0
        thread[:child_job_override] = thread[:child_job]

        captured_output = job.capture_output ? (job.output || String.new(encoding: 'UTF-8')) : nil
        if captured_output
          job.output = captured_output
          thread[:captured_output] = captured_output
        elsif inline_child && snapshot[:captured_output]
          thread[:captured_output] = snapshot[:captured_output]
        end

        LibraryBus.initialize_queue(thread)
        app.args_dispatch.set_env_variables(app.env_flags, job.env_flags || {})
        job.status = :running
        job.started_at = Time.now

        begin
          Librarian.run_command(job.args.dup, job.internal, job.task, &job.block)
        ensure
          job.output = captured_output.dup if captured_output
          if job.child.to_i.positive?
            if thread[:parent]
              merge_notifications(thread, thread[:parent])
              if thread[:email_msg]
                thread[:parent][:email_msg] ||= String.new(encoding: 'UTF-8')
                thread[:parent][:email_msg] << thread[:email_msg].to_s
              end
              if thread[:send_email].to_i.positive?
                thread[:parent][:send_email] = thread[:send_email].to_i
              end
            elsif inline_child
              preserved_email = false
              if thread[:email_msg]
                snapshot[:email_msg] ||= String.new(encoding: 'UTF-8')
                snapshot[:email_msg].force_encoding('UTF-8') if snapshot[:email_msg].encoding == Encoding::ASCII_8BIT
                snapshot[:email_msg] << thread[:email_msg].to_s.force_encoding('UTF-8')
                preserved_email = true
              end
              if preserved_email && thread[:send_email].to_i.positive?
                snapshot[:send_email] = thread[:send_email].to_i
              end
            elsif thread[:log_msg]
              parent_daemon = thread[:parent_daemon]
              if parent_daemon
                thread[:log_msg].to_s.each_line do |line|
                  app.speaker.daemon_send(line, thread: thread, daemon: parent_daemon)
                end
              else
                app.speaker.speak_up(thread[:log_msg].to_s, -1, thread, 1)
              end
            end
          end
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
      prune_finished_jobs(limit_per_queue: finished_jobs_limit_per_queue)
      unregister_child(job)
    end

    def prune_finished_jobs(limit_per_queue:)
      limit = limit_per_queue.to_i
      if limit <= 0
        finished_jobs_by_queue(job_registry.values).each_value do |entries|
          entries.each do |job|
            next if job_within_retention_period?(job)

            discard_job(job)
          end
        end
        return
      end

      finished_jobs_by_queue(job_registry.values).each_value do |entries|
        excess = entries.size - limit
        next unless excess.positive?

        entries.sort_by { |job| finished_at_time(job) }
               .first(excess)
               .each do |job|
          next if job_within_retention_period?(job)

          discard_job(job)
        end
      end
    end

    # Drop a job record and everything keyed by its id, or the per-job
    # library bus queue and children map leak for the daemon's lifetime.
    def discard_job(job)
      id = job_attribute(job, :id)
      @jobs.delete(id)
      job_children.delete(id) if job_children.respond_to?(:delete)
      LibraryBus.remove_queue(id) if defined?(LibraryBus)
    end

    def job_within_retention_period?(job)
      return false unless job_attribute(job, :capture_output)

      raw_finished_at = job_attribute(job, :finished_at)
      return false unless raw_finished_at

      finished_at = coerce_time(raw_finished_at)
      return false unless finished_at

      Time.now - finished_at < CAPTURE_OUTPUT_RETENTION_SECONDS
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
  end
end

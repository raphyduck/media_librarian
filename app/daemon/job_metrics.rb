# frozen_string_literal: true

# Job serialization and queue metrics for the daemon's /jobs and /status
# endpoints: turning Job structs into API hashes, grouping/sorting by queue,
# computing per-queue running/queued/finished counts, and trimming the retained
# finished-job history. Reopens Daemon's singleton class so these methods stay
# byte-for-byte identical to their prior inline definitions; extracted purely to
# shrink app/daemon.rb. Zeitwerk is told to ignore this file (see
# Application#setup_loader) because it reopens Daemon rather than defining a
# Daemon::JobMetrics constant.

class Daemon
  class << self
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

    def queue_metrics_for(running:, queued:, finished:, include_finished: true)
      metrics = Hash.new do |hash, key|
        entry = { 'queue' => key, 'running' => 0, 'queued' => 0, 'total' => 0 }
        entry['finished'] = 0 if include_finished
        hash[key] = entry
      end

      { 'running' => running, 'queued' => queued, 'finished' => finished }.each do |key, jobs|
        next if key == 'finished' && !include_finished

        jobs.each do |job|
          queue = job_attribute(job, :queue).to_s
          entry = metrics[queue]
          entry[key] += 1
          entry['total'] += 1
        end
      end

      metrics.values
             .select do |entry|
               queue = entry['queue'].to_s
               next true unless queue.match?(UUID_REGEX)

               (entry['running'] + entry['queued']).positive?
             end
             .sort_by { |entry| entry['queue'] }
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

    def finished_jobs_limit_per_queue
      app.finished_jobs_per_queue.to_i
    end

    def finished_job?(job)
      finished_at = job_attribute(job, :finished_at)
      finished_at || FINISHED_STATUSES.include?(job_attribute(job, :status).to_s)
    end

    def finished_jobs_by_queue(jobs)
      jobs.select { |job| finished_job?(job) }
          .group_by { |job| job_attribute(job, :queue).to_s }
    end

    def finished_at_time(job)
      coerce_time(job_attribute(job, :finished_at)) || Time.at(0)
    end

    def trim_finished_jobs(jobs, limit)
      limit = limit.to_i
      return jobs.reject { |job| finished_job?(job) } if limit <= 0

      keep_ids = {}
      finished_jobs_by_queue(jobs).each_value do |entries|
        entries.sort_by { |job| finished_at_time(job) }
               .last(limit)
               .each do |job|
          job_id = job_attribute(job, :id)
          keep_ids[job_id] = true if job_id
        end
      end

      jobs.reject do |job|
        next false unless finished_job?(job)

        job_id = job_attribute(job, :id)
        job_id && !keep_ids[job_id]
      end
    end
  end
end

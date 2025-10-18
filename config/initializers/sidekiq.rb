require 'set'
require 'sidekiq'
require 'sidekiq/api'

module MediaLibrarian
  module SidekiqConfig
    extend self

    def extract_queue_names(actions)
      return Set.new unless actions.respond_to?(:each)

      actions.each_with_object(Set.new) do |(_, value), result|
        case value
        when Hash
          result.merge(extract_queue_names(value))
        when Array
          queue = value[3]
          result.add(queue.to_s) if queue && !queue.to_s.empty?
        end
      end
    end

    def media_librarian_queues
      queues = Set.new(%w[default scheduler])
      queues.merge(extract_queue_names($available_actions))
      queues.to_a.map { |name| Daemon.normalize_queue(name, nil) }.reject(&:empty?).uniq
    end

    def scheduler_enqueued?(template_name)
      return true if Sidekiq::Queue.new('scheduler').any? do |job|
        job.klass == SchedulerJob.name && job.args.first == template_name
      end

      return true if Sidekiq::ScheduledSet.new.any? do |job|
        job.klass == SchedulerJob.name && job.args.first == template_name
      end

      Sidekiq::Workers.new.any? do |_, _, work|
        payload = work['payload'] || {}
        payload['class'] == SchedulerJob.name && Array(payload['args']).first == template_name
      end
    end
  end
end

redis_config = $config['redis'] || {}
redis_url = redis_config['url'] || ENV['REDIS_URL'] || 'redis://127.0.0.1:6379/0'
redis_namespace = redis_config['namespace'] || 'media_librarian'
pool_size = ($config.dig('daemon', 'workers_pool_size') || 4).to_i

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url, namespace: redis_namespace }
  config.concurrency = pool_size if pool_size.positive?
  config.queues = MediaLibrarian::SidekiqConfig.media_librarian_queues

  config.on(:startup) do
    template = 'scheduler'
    SchedulerJob.perform_async(template) unless MediaLibrarian::SidekiqConfig.scheduler_enqueued?(template)
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: redis_url, namespace: redis_namespace }
end

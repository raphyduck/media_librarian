require 'sidekiq'

class ApplicationJob
  include Sidekiq::Job

  sidekiq_options retry: false

  ACQUIRE_SCRIPT = <<~LUA.freeze
    local current = redis.call('GET', KEYS[1])
    if current and tonumber(current) >= tonumber(ARGV[1]) then
      return 0
    end
    redis.call('INCR', KEYS[1])
    redis.call('EXPIRE', KEYS[1], ARGV[2])
    return 1
  LUA

  RELEASE_SCRIPT = <<~LUA.freeze
    local current = redis.call('GET', KEYS[1])
    if not current then
      return 0
    end
    if tonumber(current) <= 1 then
      redis.call('DEL', KEYS[1])
      return 0
    end
    redis.call('DECR', KEYS[1])
    return 1
  LUA

  private

  def with_concurrency_limit(queue_name, limit, _jid)
    return yield if limit.nil? || limit <= 0

    key = "media_librarian:queue:#{queue_name}:running"
    acquired = false
    begin
      until acquired
        acquired = acquire_slot(key, limit)
        sleep 1 unless acquired
      end
      yield
    ensure
      release_slot(key) if acquired
    end
  end

  def acquire_slot(key, limit)
    limit = limit.to_i
    Sidekiq.redis do |conn|
      conn.call('EVAL', ACQUIRE_SCRIPT, 1, key, limit, 3600)
    end.to_i == 1
  end

  def release_slot(key)
    Sidekiq.redis do |conn|
      conn.call('EVAL', RELEASE_SCRIPT, 1, key)
    end
  end
end

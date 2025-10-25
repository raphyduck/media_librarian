# frozen_string_literal: true

module ThreadState
  module_function

  def around(thread)
    snapshot = capture(thread)
    yield snapshot
  ensure
    restore(thread, snapshot)
  end

  def capture(thread)
    thread.keys.each_with_object({}) do |key, memo|
      memo[key] = thread[key]
    end
  end
  private_class_method :capture

  def restore(thread, snapshot)
    return unless snapshot

    snapshot.each do |key, value|
      thread[key] = key == :parent && value.equal?(thread) ? nil : value
    end

    (thread.keys - snapshot.keys).each do |key|
      thread[key] = nil
    end
  end
  private_class_method :restore
end

class Array
  def deep_dup
    map do |value|
      begin
        if value.respond_to?(:deep_dup)
          value.deep_dup
        else
          value.dup
        end
      rescue StandardError
        value
      end
    end
  end
end

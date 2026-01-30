class TimeUtils
  UNITS = [['day', 86400], ['hour', 3600], ['minute', 60], ['second', 1]].freeze

  def self.seconds_in_words(total_seconds)
    return '' if total_seconds.to_f <= 0

    parts = []
    remaining = total_seconds.to_f
    UNITS.each do |name, divisor|
      value, remaining = remaining.divmod(divisor)
      value = value.floor
      parts << "#{value} #{name}#{StringUtils.pluralize(value)}" if value > 0
    end
    parts << "#{remaining.round(3)} second#{StringUtils.pluralize(remaining)}" if remaining > 0 && parts.empty?
    parts.join(', ')
  end
end
class TimeUtils

  def self.seconds_in_words(s)
    # d = days, h = hours, m = minutes, s = seconds
    m = (s / 60).floor
    s = s % 60
    h = (m / 60).floor
    m = m % 60
    d = (h / 24).floor
    h = h % 24
    output = ""
    output = "#{d} day#{StringUtils.pluralize(d)}" if d > 0
    output += "#{StringUtils.commatize(output)}#{h} hour#{StringUtils.pluralize(h)}" if h > 0
    output += "#{StringUtils.commatize(output)}#{m} minute#{StringUtils.pluralize(m)}" if m > 0
    output += "#{StringUtils.commatize(output)}#{s.round(3)} second#{StringUtils.pluralize(s)}" if s > 0
    output
  end

end
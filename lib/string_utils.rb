class StringUtils

  def self.accents_clear(str)
    if str.is_a? String
      fix_encoding(str).tr(
          "ÀÁÂÃÄÅàáâãäåĀāĂăĄąÇçĆćĈĉĊċČčÐðĎďĐđÈÉÊËèéêëĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĦħÌÍÎÏìíîïĨĩĪīĬĭĮįİıĴĵĶķĸĹĺĻļĽľĿŀŁłÑñŃńŅņŇňŉŊŋÒÓÔÕÖØòóôõöøŌōŎŏŐőŔŕŖŗŘřŚśŜŝŞşŠšſŢţŤťŦŧÙÚÛÜùúûüŨũŪūŬŭŮůŰűŲųŴŵÝýÿŶŷŸŹźŻżŽž",
          "AAAAAAaaaaaaAaAaAaCcCcCcCcCcDdDdDdEEEEeeeeEeEeEeEeEeGgGgGgGgHhHhIIIIiiiiIiIiIiIiIiJjKkkLlLlLlLlLlNnNnNnNnnNnOOOOOOooooooOoOoOoRrRrRrSsSsSsSssTtTtTtUUUUuuuuUuUuUuUuUuUuWwYyyYyYZzZzZz")
    elsif str.is_a? Array
      str.map { |s| accents_clear(s) }
    elsif str.is_a? Hash
      Hash[str.map { |k, v| [accents_clear(k), accents_clear(v)] }]
    else
      str
    end
  end

  def self.fix_encoding(str)
    str.encode(Encoding.find('UTF-8'), {invalid: :replace, undef: :replace, replace: ''})
  end

  def self.clean_search(str)
    accents_clear(str).gsub(/[,\'\:\&\-\?\!]/, '').gsub(/^the[#{SPACE_SUBSTITUTE}](\w+.*)/i, '\1').
        gsub(/([Tt]he)?.T[Vv].[Ss]eries/, '').gsub(/[#{SPACE_SUBSTITUTE}]\(?(US|UK)\)?$/, '')
  end

  def self.commatize(previous)
    previous != '' ? ', ' : ''
  end

  def self.gsub(string, old, new)
    if old.is_a?(Array)
      old.each { |s| string = string.gsub(/#{s}/i, new) }
    else
      string = string.gsub(/#{old}/i, new)
    end
    string
  end

  def self.intersection(str1, str2)
    return '' if [str1, str2].any?(&:empty?) || str1[0] != str2[0]
    matrix = Array.new(str1.length) { Array.new(str2.length) { 0 } }
    intersection_length = 0
    intersection_end = 0
    str1.length.times do |x|
      break unless str1[x] == str2[x]
      str2.length.times do |y|
        next unless str1[x] == str2[y]
        matrix[x][y] = 1 + (([x, y].all?(&:zero?)) ? 0 : matrix[x - 1][y - 1])

        next unless matrix[x][y] > intersection_length
        intersection_length = matrix[x][y]
        intersection_end = x
      end
    end
    intersection_start = intersection_end - intersection_length + 1

    str1.slice(intersection_start..intersection_end)
  end

  def self.pluralize(number)
    number > 1 ? "s" : ""
  end

  def self.regexify(str)
    str = str.dup
    str.gsub!('?', '\?')
    str.gsub!(/\(([^\(\)]{5,})\)/, '\(?\1\)?')
    sep_chars = '[:,-_\. ]{1,2}'
    trailing_sep = ''
    d = str.match(/.*:([\. \w]+)(.+)?/)
    if d
      trailing_sep = sep_chars if d[2]
      d = d[1]
      str.gsub!(d, '<placeholder>') if d
      d = d.scan(/(\w)(\w+)?/).map { |e| "#{e[0]}#{'(' + e[1].to_s + ')?' if e[1]}" if e[0] }.join('[\. ]?')
    end
    e = str.match(/.*[#{SPACE_SUBSTITUTE}]+([A-Z]+)[#{SPACE_SUBSTITUTE}]*$/)
    if e
      e = e[1]
      str.gsub!(e, '<placeholder2>') if e
      e = e.chars.map{|w| "#{w}([a-z]+[#{SPACE_SUBSTITUTE}]?)?"}.join
    end
    str = str.strip.gsub("'", "'?").gsub('+', '.').gsub('$', '.').gsub(/(\w)s([#{SPACE_SUBSTITUTE}])/, '\1\'?s\2')
    str = str.gsub(/(\w)re([#{SPACE_SUBSTITUTE}])/, '\1\'?re\2')
    str = str.gsub(/[:,-\/\[\]!]([^\?]|$)/, '.?\1').gsub(/[#{SPACE_SUBSTITUTE}]+([^\?]|$)/, sep_chars + '\1')
    str.gsub!(/(&|and|et)/i, '(&|and|et)')
    str.gsub!(/le\'\?s\[:,-_\\\. \]\{1,2\}/i, '(les )?')
    str.gsub!('<placeholder>', "#{sep_chars}#{d}#{trailing_sep}") if d
    str.gsub!('<placeholder2>', "#{e}#{trailing_sep}") if e
    str
  end

  def self.regularise_media_filename(filename, formatting = '')
    filename = filename.join if filename.is_a?(Array)
    r = filename.to_s.gsub(/[\'\"\;\:\,]/, '').gsub(/\//, ' ')
    r = r.downcase.titleize if formatting.to_s.gsub(/[\(\)]/, '').match(/.*titleize.*/)
    r = r.downcase if formatting.to_s.match(/.*downcase.*/)
    r = r.gsub(/[\ \(\)]/, '.') if formatting.to_s.match(/.*nospace.*/)
    r
  end

  def self.title_match_string(str, strict = 1)
    year = Metadata.identify_release_year(str).to_i
    str = str.gsub(/\((\d{4})\)$/, '\(?(' + (year - 1).to_s + '|\1|' + (year + 1).to_s + ')\)?')
    str = '(\/|^)([Tt]he )?' + regexify(clean_search(str))
    str << '.{0,7}$' if strict.to_i > 0
    str
  end
end
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
    regularise_media_filename(accents_clear(str)).gsub(/^the[#{SPACE_SUBSTITUTE}](\w+.*)/i, '\1').
        gsub(/([Tt]he)?.T[Vv].[Ss]eries/, '').gsub(/[#{SPACE_SUBSTITUTE}]\(?(US|UK)\)?$/, '').gsub(/([#{SPACE_SUBSTITUTE}])+/, '\1')
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
    if str.match(/[#{SPACE_SUBSTITUTE}&]/)
      str = str.scan(/[^#{SPACE_SUBSTITUTE}&]+/).map { |e| regexify(e) }.select { |s| s.to_s != '' }.join("([#{SPACE_SUBSTITUTE}&-]|and|et){1,3}")
    elsif str.match(/^[A-Z][A-Z]+$/)
      str = str.chars.map { |w| "#{w}([a-z]+[#{SPACE_SUBSTITUTE}]?)?" }.join
    else
      return '' if str.match(/^(&|and|et)$/i)
      str.gsub!('?', '\?')
      str = str.strip.gsub("'", "'?").gsub('+', '.').gsub('$', '.').gsub(/[:,-\/\[\]!\(\)]/, '.?').gsub(/(\w)s$/, '\1[\' \.]?s')
      str = str.gsub(/(\w)re$/, '\1\'?re')
      str.gsub!(/^l(\w)/i, 'l[\' _]?\1')
      if str.match(/(l[ae]s?)/i)
        str.gsub!(/(l[ae]s?)/i, '(\1)?')
      else
        str = "#{str[0]}(#{str.chars.drop(1).join})?" if str.chars.count > 1 && str.match(/^\w.+/)
      end
    end
    str
  end

  def self.regularise_media_filename(filename, formatting = '')
    filename = filename.join if filename.is_a?(Array)
    r = filename.to_s.gsub(/[\'\"\;\,]/, '').gsub(/[\/·\:]/, ' ')
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
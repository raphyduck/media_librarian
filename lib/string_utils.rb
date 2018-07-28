class StringUtils

  def self.clean_search(str)
    str.gsub(/[,\'\:\&]/, '')
  end

  def self.clear_extension(filename)
    filename.gsub(Regexp.new(VALID_VIDEO_EXT), '\1')
  end

  def self.commatize(previous)
    previous != '' ? ', ' : ''
  end

  def self.intersection(str1, str2)
    return '' if [str1, str2].any?(&:empty?) || str1[0] != str2[0]
    matrix = Array.new(str1.length) { Array.new(str2.length) { 0 } }
    intersection_length = 0
    intersection_end    = 0
    str1.length.times do |x|
      break unless str1[x] == str2[x]
      str2.length.times do |y|
        next unless str1[x] == str2[y]
        matrix[x][y] = 1 + (([x, y].all?(&:zero?)) ? 0 : matrix[x-1][y-1])

        next unless matrix[x][y] > intersection_length
        intersection_length = matrix[x][y]
        intersection_end    = x
      end
    end
    intersection_start = intersection_end - intersection_length + 1

    str1.slice(intersection_start..intersection_end)
  end

  def self.pluralize(number)
    number > 1 ? "s" : ""
  end

  def self.prepare_str_search(str)
    clear_extension(str).downcase.gsub(/[_]/, ' ')
  end

  def self.regexify(str)
    sep_chars = '[:,-_\. ]{1,2}'
    trailing_sep = ''
    d=str.match(/.*:([\. \w]+)(.+)?/)
    if d
      trailing_sep = sep_chars if d[2]
      d = d[1]
      str.gsub!(d, '<placeholder>') if d
      d=d.scan(/(\w)(\w+)?/).map { |e| "#{e[0]}#{'(' + e[1].to_s + ')?' if e[1]}" if e[0] }.join('[\. ]?')
    end
    str = str.strip.gsub("'", "'?").gsub(/(\w)s /, '\1\'?s ')
    str = str.gsub(/[:,-\/\[\]!]([^\?]|$)/, '.?\1').gsub(/[#{SPACE_SUBSTITUTE}]+([^\?]|$)/, sep_chars + '\1')
    str.gsub!(/(&|and|et)/, '(&|and|et)')
    str.gsub!(/le\'\?s\[:,-_\\\. \]\{1,2\}/i, '(les )?')
    str.gsub!('<placeholder>', "#{sep_chars}#{d}#{trailing_sep}") if d
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
    year = MediaInfo.identify_release_year(str).to_i
    str = str.gsub(/\((\d{4})\)$/, '\(?(' + (year - 1).to_s + '|\1|' + (year + 1).to_s + ')\)?')
    str = '(\/|^)([Tt]he )?' + regexify(str.gsub(/^[Tt]he /, '').gsub(/([Tt]he)?.T[Vv].[Ss]eries/, '').gsub(/ \(US\)$/, ''))
    str << '.{0,7}$' if strict.to_i > 0
    str
  end
end
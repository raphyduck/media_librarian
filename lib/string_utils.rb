class StringUtils

  def self.clean_search(str)
    str.gsub(/[,\']/, '')
  end

  def self.clear_extension(filename)
    filename.gsub(Regexp.new(VALID_VIDEO_EXT), '\1')
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
    str.gsub!(/(&|and)/, '(&|and)')
    str.gsub!('<placeholder>', "#{sep_chars}#{d}#{trailing_sep}") if d
    str
  end

  def self.regularise_media_filename(filename, formatting = '')
    r = filename.to_s.gsub(/[\'\"\;\:\,]/, '').gsub(/\//, ' ')
    r = r.downcase.titleize if formatting.to_s.gsub(/[\(\)]/, '').match(/.*titleize.*/)
    r = r.downcase if formatting.to_s.match(/.*downcase.*/)
    r = r.gsub(/[\ \(\)]/, '.') if formatting.to_s.match(/.*nospace.*/)
    r
  end

  def self.title_match_string(str)
    '^([Tt]he )?' + regexify(str.gsub(/(\w*)\(\d+\)/, '\1').gsub(/^[Tt]he /, '').gsub(/([Tt]he)?.T[Vv].[Ss]eries/, '').gsub(/ \(US\)$/, '')) + '.{0,7}$'
  end
end
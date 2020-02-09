class Languages

  def self.get_code(from_language)
    LANG_ADJUST.select { |_, langs| langs.include?(from_language) }.first[0].to_s rescue nil
  end

  def self.sort_languages(preferred_langs)
    llist = LANG_ADJUST.dup
    (preferred_langs.to_s.split(' ').map { |l| llist.delete(l.to_sym) } + llist.map { |_, ls| ls }).flatten
  end
end
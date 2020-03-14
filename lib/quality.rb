class Quality

  def self.detect_file_quality(file, fileinfo = nil, mv = 0, ensure_qualities = '', type = '')
    qualities = []
    return file, qualities unless file.match(Regexp.new(VALID_VIDEO_EXT))
    fileinfo = FileInfo.new(file) if fileinfo.nil?
    nfile = File.basename(file)
    (Q_SORT + ['DIMENSIONS', 'EXTRA_TAGS']).each do |qtitle|
      q = fileinfo.quality(qtitle)
      unless q.nil?
        nfile = filename_quality_change(nfile, q, eval(qtitle) - q, type)
        ensure_qualities = filename_quality_change(ensure_qualities, q, eval(qtitle) - q, type)
      end
      qualities += parse_qualities("#{nfile}.#{ensure_qualities}", eval(qtitle), '', type)
    end
    nfile = File.dirname(file) + '/' + nfile
    FileUtils.mv(file, nfile) if file != nfile && mv.to_i > 0
    return nfile, qualities
  end

  def self.filename_quality_change(filename, new_qualities, replaced_qualities = [], type = '')
    extension = FileUtils.get_extension(filename)
    (Q_SORT + ['EXTRA_TAGS']).each do |t|
      file_q = parse_qualities(filename, eval(t), '', type)
      t_q = parse_qualities(".#{new_qualities.join('.')}.", eval(t), '', type)
      r_q = parse_qualities(".#{replaced_qualities.join('.')}.", eval(t), '', type)
      r_q -= t_q
      next if (r_q - t_q).empty? && (t_q - r_q).empty?
      if (file_q - r_q) != file_q
        $speaker.speak_up "Removing qualities information '#{r_q.join('.')}' from file '#{filename}'..." if Env.debug?
        filename = qualities_replace(filename, r_q)
      end
      unless (t_q - file_q).empty?
        old_filename = filename.dup
        filename = qualities_replace(filename, file_q)
        t_q.each { |q| filename = filename.gsub(/\.#{extension}$/, '').to_s + ".#{q}.#{extension}" }
        $speaker.speak_up "File '#{old_filename}' does not contain the qualities information '#{t_q.join('.')}', should be '#{filename}'" if Env.debug?
      end
    end
    filename
  end

  def self.filter_quality(filename, qualities, language = '', assume_quality = nil, category = '')
    timeframe = ''
    unless parse_qualities(filename, ['hc']).empty?
      $speaker.speak_up "'#{filename}' contains hardcoded subtitles, removing from list" if Env.debug?
      return timeframe, false
    end
    file_q = parse_qualities(filename, VALID_QUALITIES, language, category)
    (qualities['illegal'].is_a?(Array) ? qualities['illegal'] : [qualities['illegal'].to_s]).each do |iq|
      next if iq.to_s == ''
      if (iq.split - file_q).empty?
        $speaker.speak_up "'#{filename}' has an illegal combination of qualities, removing from list" if Env.debug?
        return timeframe, false
      end
    end
    if qualities['strict'].to_i > 0 && (file_q - qualities['min_quality'].split(' ')).empty?
      $speaker.speak_up "Strict minimum quality is excluded and '#{filename}' has only the strict minimum, removing from list" if Env.debug?
      return timeframe, false
    end
    return timeframe, true if qualities.nil? || qualities.empty?
    Q_SORT.each do |t|
      file_q = parse_qualities(filename, eval(t), language, category)[0].to_s
      file_q = parse_qualities((assume_quality.to_s), eval(t), language, category)[0].to_s if file_q.empty?
      if qualities_compare(qualities['min_quality'], t, file_q, '<', "'#{filename}' is of lower quality than the minimum required, removing from list")
        return timeframe, false
      end
      if qualities_compare(qualities['max_quality'], t, file_q, '>', "'#{filename}' is of higher quality than the maximum allowed, removing from list")
        return timeframe, false
      end
      if qualities_compare((qualities['target_quality'] || qualities['max_quality']), t, file_q, '<', "'#{filename}' is of lower quality than the target quality, setting timeframe '#{qualities['timeframe']}'") &&
          timeframe == ''
        timeframe = qualities['timeframe'].to_s
      end
    end
    return timeframe, true
  end

  def self.identify_proper(filename)
    p = File.basename(filename).downcase.match(/[\. ](proper|repack)[\. ]/).to_s.gsub(/[\. ]/, '').gsub(/(repack|real)/, 'proper')
    return p, (p != '' ? 1 : 0)
  end

  def self.media_qualities(filename, language = '', assume_qualities = '', category = '')
    q = {}
    Q_SORT.each do |t|
      q[t.downcase] = parse_qualities(filename, eval(t), language, category).first.to_s
      q[t.downcase] = parse_qualities(assume_qualities, eval(t), language, category).first.to_s if q[t.downcase].empty? && assume_qualities.to_s != ''
    end
    q['proper'] = identify_proper(filename)[1]
    q
  end

  def self.media_list_qualities(file, type = 'file')
    qualities = if file[:files]
                  file[:files].select { |f| f[:type] == type }.map do |f|
                    Q_SORT.map do |qt|
                      parse_qualities(f[:name], eval(qt), f[:language], f[:type])[0]
                    end
                  end.compact.flatten.uniq
                else
                  []
                end
    qualities = qualities_min(qualities)
    qualities
  end

  def self.parse_3d(filename, qs)
    return qs unless qs.include?('3d')
    qs.delete_if { |q| q.include?('3d') }
    if filename.downcase.match(/#{SEP_CHARS}top.{0,3}bottom#{SEP_CHARS}/)
      qs << '3d.tab'
    else
      qs << '3d.sbs'
    end
    qs
  end

  def self.parse_qualities(filename, qc = VALID_QUALITIES, language = '', type = '')
    _, filename, _ = Metadata.detect_metadata(filename, type)
    filename = qualities_replace(filename + '.ext', LANG_ADJUST[language.to_sym], '.vo.') if language.to_s != '' && LANG_ADJUST[language.to_sym].is_a?(Array) #Lets adjust language qualities first
    pq = (filename + '.ext').downcase.gsub(/([\. ](h|x))[\. ]?(\d{3})/, '\1\3').scan(Regexp.new('(?=((^|' + SEP_CHARS + ')(' + qc.map { |q| q.gsub('.', '[\. ]').gsub('+', '[+]') }.join('|') + ')' + SEP_CHARS + '))')).
        map { |q| q[2] }.flatten.map do |q|
      q.gsub(/^[ \.\(\)\-](.*)[ \.\(\)\-]$/, '\1').gsub('-', '').gsub('hevc', 'x265').gsub('avc', 'x264').gsub('h26', 'x26').gsub(' ', '.')
    end.uniq.flatten.sort_by { |q| VALID_QUALITIES.index(q) }
    pq = parse_3d(filename, pq)
    pq << 'multi' if (pq & LANGUAGES).count > 1 && !pq.include?('multi')
    pq
  end

  def self.qualities_array_compare(arr, comparison)
    min = []
    until arr.empty? do
      cmin = arr.shift
      arr.delete_if do |q|
        delete = false
        Q_SORT.each do |t|
          if eval(t).include?(cmin) && eval(t).include?(q)
            cmin = q if eval(t).index(q).send(comparison, eval(t).index(cmin))
            delete = true
          end
        end
        delete
      end
      min << cmin if cmin
    end
    min
  end

  def self.qualities_compare(qualities, type, qt, comparison, message = '')
    qualities.to_s.split(' ').each do |q|
      if eval(type).include?(q) && ((qt.empty? && comparison == '<') || (!qt.empty? && eval(type).index(q).send(comparison, eval(type).index(qt))))
        $speaker.speak_up "#{message} (target '#{q}')" if Env.debug? && message.to_s != ''
        return true
      end
    end
    return false
  end

  def self.qualities_file_filter(file, qualities)
    accept = true
    if !qualities.nil? && !qualities.empty? && (qualities['target_quality'] || qualities['max_quality'])
      existing_qualities, min_q = qualities_set_minimum(file, (qualities['target_quality'] || qualities['max_quality']))
      _, accept = filter_quality(
          '.' + existing_qualities.join('.') + '.',
          {'min_quality' => min_q}, file[:language], nil, file[:type]
      )
      $speaker.speak_up "Ignoring file '#{file[:full_name]}' as it is lower than minimum quality '#{(qualities['target_quality'] || qualities['max_quality'])}'" if Env.debug? && !accept
    end
    accept
  end

  def self.qualities_max(arr)
    qualities_array_compare(arr, '<')
  end

  def self.qualities_merge(oq, aq, lang = '', category = '')
    quality = ''
    Q_SORT.each do |t|
      cq = parse_qualities(oq.to_s, eval(t), lang, category).join('.')
      cq = parse_qualities((aq.to_s), eval(t), lang, category).join('.') if cq.to_s == ''
      quality += ".#{cq}"
    end
    quality
  end

  def self.qualities_min(arr)
    qualities_array_compare(arr, '>')
  end

  def self.qualities_replace(str, qualities = [], replace_with = nil)
    replace_with = '\1' if replace_with.nil?
    qualities.each do |q|
      str = str.gsub(Regexp.new('(^|' + SEP_CHARS + ')(' + q + ')' + SEP_CHARS, Regexp::IGNORECASE), replace_with)
    end
    str
  end

  def self.qualities_set_minimum(file, reference_q, incomplete = 0)
    existing_qualities = incomplete.to_i == 0 ? media_list_qualities(file, 'file') : ''
    unless existing_qualities.empty?
      reference_q = qualities_max(reference_q.to_s.split(' ') + existing_qualities.dup).join(' ')
      $speaker.speak_up "File(s) of '#{file[:full_name]}' already existing with a quality of '#{existing_qualities}', setting minimum quality to '#{reference_q}'" if Env.debug?
    end
    return existing_qualities, reference_q
  end

  def self.sort_media_files(files, qualities = {}, language = '', category = '')
    sorted, r = [], []
    files.each do |f|
      qs = media_qualities(File.basename(f[:name]), language, f[:assume_quality].to_s, category)
      q_timeframe, accept = filter_quality(f[:name], qualities, language, f[:assume_quality], category)
      if accept
        timeframe_waiting = Utils.timeperiod_to_sec(q_timeframe).to_i
        sorted << [f[:name], qs['resolutions'], qs['sources'], qs['codecs'], qs['audio'], qs['proper'], qs['languages'], qs['cut'],
                   (f[:timeframe_tracker].to_i + f[:timeframe_size].to_i + timeframe_waiting)]
        r << f.merge({:timeframe_quality => Utils.timeperiod_to_sec(q_timeframe).to_i})
      end
    end
    sorted.sort_by! { |x| (AUDIO.index(x[4]) || 999).to_i }
    sorted.sort_by! { |x| -x[5].to_i }
    sorted.sort_by! { |x| (CUT.index(x[7]) || 999).to_i }
    sorted.sort_by! { |x| (CODECS.index(x[3]) || 999).to_i }
    sorted.sort_by! { |x| (LANGUAGES.index(x[6]) || 999).to_i }
    sorted.sort_by! { |x| (SOURCES.index(x[2]) || 999).to_i }
    sorted.sort_by! { |x| (RESOLUTIONS.index(x[1]) || 999).to_i }
    sorted.sort_by! { |x| x[8].to_i }
    r.sort_by! { |f| sorted.map { |x| x[0] }.index(f[:name]) }
  end

end
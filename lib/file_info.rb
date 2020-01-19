class FileInfo
  attr_accessor :media_info, :path

  def initialize(path)
    @media_info = MediaInfo.from(path)
    @path = path
  end

  def getaudiochannels
    ac = [media_info.audio]
    tr_nb = 2
    while eval("media_info.audio#{tr_nb}?")
      ac += [eval("media_info.audio#{tr_nb}")]
      tr_nb += 1
    end
    ac
  end

  def getcolor
    media_info.video.colour_primaries.to_s rescue ''
  end

  def getbit
    media_info.video.bitdepth.to_s rescue ''
  end

  def getvcodec(format = 0)
    c = media_info.video.format rescue nil
    if format.to_i > 0
      if c.downcase.gsub("-", "") == "mpeg4" || c.downcase.gsub("-", "") == "msmpeg4" or c.downcase.gsub("-", "") == "msmpeg4v1" or c.downcase.gsub("-", "") == "msmpeg4v2" or c.downcase.gsub("-", "") == "msmpeg4v3"
        'xvid'
      elsif c.downcase.gsub("-", "") == "vc1"
        'vc1'
      elsif c.downcase.gsub("-", "").include?("wmv")
        'wmv'
      elsif c.downcase.gsub("-", "") == "h264" or c.downcase.gsub("-", "") == "avc" or c.downcase.gsub("-", "") == "h264"
        'x264'
      elsif c.downcase.gsub("-", "") == "hevc" or c.downcase.gsub("-", "") == "h265" or c.downcase.gsub("-", "") == "h.265"
        'x265'
      elsif c.downcase.gsub("-", "") == "mpeg2" or c.downcase.gsub("-", "") == "mpeg2video"
        'mpeg2'
      elsif c.downcase.gsub("-", "") == "vp9"
        'vp9'
      else
        c.downcase.gsub("-", "")
      end
    else
      c
    end
  end

  def getoptivcodec(codec, hq = false)
    if codec.to_s == ''
      return false
    elsif codec.downcase.gsub("-", "") == "vc1"
      #vc1 encoding is not supported by ffmpeg so codec is changed to h.264
      return('libx264')
    elsif codec.downcase.gsub("-", "").include?("wmv")
      #upgrades codec to wmv3 if wmv1/2 who wants to use outdated codecs anyway
      return('wmv3')
    elsif codec.downcase.gsub("-", "") == "mpeg4"
      return('libxvid')
    elsif codec.downcase.gsub("-", "") == "msmpeg4" or codec.downcase.gsub("-", "") == "msmpeg4v1" or codec.downcase.gsub("-", "") == "msmpeg4v2" or codec.downcase.gsub("-", "") == "msmpeg4v3"
      #Should encode to msmpeg4v3 there is no standalose encoder for V2 and V1 can not be encoded
      return('msmpeg4')
    elsif codec.downcase.gsub("-", "") == "h264" or codec.downcase.gsub("-", "") == "avc" or codec.downcase.gsub("-", "") == "h264"
      return('libx264')
    elsif codec.downcase.gsub("-", "") == "hevc" or codec.downcase.gsub("-", "") == "h265" or codec.downcase.gsub("-", "") == "h.265"
      return('libx265')
    elsif codec.downcase.gsub("-", "") == "mpeg2" or codec.downcase.gsub("-", "") == "mpeg2video"
      return('mpeg2video')
    elsif codec.downcase.gsub("-", "") == "vp9"
      return('libvpx-vp9')
    elsif hq
      return('libx265')
    else
      #h.264 is a good fallback
      return('libx264')
    end
  end

  def getoptivcodecparams(codec, crf = 20, preset = 'medium')
    if codec.to_s == ''
      return []
    elsif codec.downcase.gsub("-", "") == "vc1"
      #vc1 encoding is not supported by ffmpeg so codec is changed to h.264
      return(['-crf', crf, '-preset', preset])
    elsif codec.downcase.gsub("-", "").include?("wmv")
      #upgrades codec to wmv3 if wmv1/2 who wants to use outdated codecs anyway
      return []
    elsif codec.downcase.gsub("-", "") == "mpeg4"
      return []
    elsif codec.downcase.gsub("-", "") == "msmpeg4" or codec.downcase.gsub("-", "") == "msmpeg4v1" or codec.downcase.gsub("-", "") == "msmpeg4v2" or codec.downcase.gsub("-", "") == "msmpeg4v3"
      #Should encode to msmpeg4v3 there is no standalose encoder for V2 and V1 can not be encoded
      return []
    elsif codec.downcase.gsub("-", "") == "h264" or codec.downcase.gsub("-", "") == "avc" or codec.downcase.gsub("-", "") == "h264"
      return(['-crf', crf, '-preset', preset])
    elsif codec.downcase.gsub("-", "") == "hevc" or codec.downcase.gsub("-", "") == "h265" or codec.downcase.gsub("-", "") == "h.265"
      return(['-crf', crf, '-preset', preset])
    elsif codec.downcase.gsub("-", "") == "mpeg2" or codec.downcase.gsub("-", "") == "mpeg2video"
      return []
    else
      return(['-crf', crf, '-preset', preset])
    end
  end

  def getresolution
    h = media_info.video.height
    st = media_info.video.scantype || "p"
    h *= 2 if st == 'Interlaced'
    r = case h
        when 0..360
          360
        when 361..480
          480
        when 481..720
          720
        when 721..1080
          1080
        else
          2160
        end
    "#{r}#{st[0].downcase}"
  end

  def isHDR?
    ishdr = false
    if getcolor.include?("BT.2020")
      ishdr = true
    end
    ishdr
  end

  def hdr_to_sdr(output)
    options = {
        custom: ['-c', 'copy', '-max_muxing_queue_size', '40000', '-map', '0', '-vf', 'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p', '-c:v', getoptivcodec(getvcodec)] + getoptivcodecparams(getvcodec)
    }
    Utils.lock_block("ffmpeg") do
      movie = FFMPEG::Movie.new(path)
      $speaker.speak_up("Running FFMpeg conversion with the following parameters: #{options[:custom]}", 0) if Env.debug?
      movie.transcode(output, options) { |progress| printf("\rProgress: %d%", (progress * 100).round(4)) }
    end
  end

  def quality(type = '')
    q = []
    case type
    when 'RESOLUTIONS'
      q += [getresolution]
    when 'CODECS'
      q += [getvcodec(1)]
      q += ['10bits'] if getbit.to_i == 10
    when 'TONES'
      q += ['hdr'] if isHDR?
    when 'AUDIO'
      ac = AUDIO.select { |a| getaudiochannels.map { |c| c.format.gsub(/[#{SPACE_SUBSTITUTE}-]/, '').downcase }.include?(a.gsub(/[#{SPACE_SUBSTITUTE}-]/, '').downcase) }.compact.uniq
      #q += ac unless ac.empty? #TODO: Better detection of audio codec
    when 'LANGUAGES'
      getaudiochannels.each do |ac|
        cq = Metadata.parse_qualities(ac.title.to_s, LANGUAGES)
        cq = [LANG_ADJUST[ac.language.to_sym].first] if cq.empty? && ac.language.to_s != '' && !LANG_ADJUST[ac.language.to_sym].nil?
        q += cq
      end
      q += ['multi'] if getaudiochannels.map { |a| a.language.to_s }.uniq.count > 1
    end
    $speaker.speak_up "#{type} quality of file #{File.basename(path)} is #{q.join('.')}" if Env.debug? && !q.empty?
    q
  end

end

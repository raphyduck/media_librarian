class FileInfo
  attr_accessor :media_info, :path

  def initialize(path)
    @media_info = MediaInfo.from(path)
    @path = path
  end

  def getcolor
    media_info.video.colour_primaries.to_s rescue ''
  end

  def getbit
    media_info.video.bitdepth.to_s rescue ''
  end

  def getvcodec
    media_info.video.format rescue nil
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

  def isHDR?
    ishdr = false
    if getcolor.include?("BT.2020")
      ishdr = true
    end
    $speaker.speak_up "#{File.basename(path)} is #{'HDR' if ishdr}#{'SDR' unless ishdr}"
    ishdr
  end

  def hdr_to_sdr(output)
    options = {
        custom: ['-c', 'copy', '-max_muxing_queue_size', '40000', '-map', '0', '-vf', 'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p', '-c:v', getoptivcodec(getvcodec)] + getoptivcodecparams(getvcodec)
    }
    movie = FFMPEG::Movie.new(path)
    $speaker.speak_up("Running FFMpeg conversion with the following parameters: #{options[:custom]}", 0) if Env.debug?
    movie.transcode(output, options) { |progress| printf("\rProgress: %d%", (progress * 100).round(4)) }
  end
end

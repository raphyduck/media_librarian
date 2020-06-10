class VideoUtils
  def self.convert_videos(path, dest_file, input_format, output_format)
    $speaker.speak_up(Utils.arguments_dump(binding)) if Env.debug?
    destination = dest_file.gsub(/(.*)\.[\w\d]{1,4}/, '\1' + ".#{output_format}")
    skipping = 0
    if output_format == 'mkv' && input_format == 'ts'
      mkvmuxer = MkvMuxer.new path, destination
      mkvmuxer.prepare
      mkvmuxer.merge!
    elsif output_format == 'mkv' && input_format == 'iso'
      #TODO: Use makemkv to convert video from iso to mkv
      # makemkvcon iso:source_file all File.dirname(destination)
    else
      skipping = 1
    end
    skipping
  end
end
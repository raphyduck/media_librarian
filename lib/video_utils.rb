require 'json'
require 'open3'

class VideoUtils
  def self.convert_videos(path, dest_file, input_format, output_format)
    MediaLibrarian.app.speaker.speak_up(Utils.arguments_dump(binding)) if Env.debug?
    destination = dest_file.gsub(/(.*)\.[\w\d]{1,4}/, '\1' + ".#{output_format}")
    skipping = 0
    if output_format == 'mkv' && ['m2ts', 'ts'].include?(input_format)
      mkv_mux = MkvMux.new path, destination
      mkv_mux.prepare
      mkv_mux.merge!(1)
    elsif output_format == 'mkv' && input_format == 'iso'
      cd = MediaLibrarian.app.temp_dir + '/' + File.basename(dest_file)
      FileUtils.mkdir_p(cd) unless File.exist?(cd)
      makemkv = MakeMkv.new(path, cd)
      makemkv.iso_to_mkv!
      FileUtils.mv(Dir["#{cd}/*.mkv"].sort_by { |f| -File.size(f) }.first, dest_file) #We will use the biggest file. This assumes the ISO is only holding 1 file of interest. But how to discern otherwise?
      FileUtils.rm(Dir["#{cd}/*.mkv"]) rescue nil
      FileUtils.rmdir(cd) if File.exist?(cd) rescue nil
    else
      skipping = 1
    end
    skipping
  end

  def self.set_default_original_audio!(path:)
    return MediaLibrarian.app.speaker.speak_up("Would set default original audio for #{path}") if Env.pretend?

    return false unless File.extname(path).downcase == '.mkv'
    return false unless system('command -v mkvpropedit >/dev/null 2>&1')
    track_map = mkv_audio_track_map(path)
    return false if track_map.empty?
    if Env.debug?
      track_langs = track_map.map { |track| track[:lang].to_s.strip.downcase }.reject(&:empty?)
      MediaLibrarian.app.speaker.speak_up("Audio tracks for #{path}: #{track_langs.join(', ')}", 0)
    end
    valid_audio = lambda do |audio|
      return false unless audio
      lang = audio[:lang].to_s.strip.downcase
      return false if lang == '' || %w[und undefined].include?(lang)
      title = audio[:name].to_s
      return false if title.downcase.include?('commentary')
      commentary = audio[:commentary].to_s.downcase
      !%w[yes true 1].include?(commentary)
    end
    target_lang = Languages.get_code(track_map.find(&valid_audio)&.dig(:lang).to_s.split('-').first)
    MediaLibrarian.app.speaker.speak_up("Default audio language target: #{target_lang}", 0) if Env.debug?
    return false if target_lang.to_s == ''

    selected_track_id = nil
    track_map.each do |audio|
      next unless valid_audio.call(audio)
      lang = audio[:lang].to_s.strip.downcase

      track_lang = Languages.get_code(lang.split('-').first)
      next if track_lang.to_s == ''
      if track_lang == target_lang
        selected_track_id = audio[:id]
        break
      end
    end

    return false unless selected_track_id

    args = ['mkvpropedit', path]
    track_map.each do |track|
      flag = (track[:id] == selected_track_id) ? '1' : '0'
      args += ['--edit', "track:@#{track[:id]}", '--set', "flag-default=#{flag}"]
    end
    return MediaLibrarian.app.speaker.speak_up("Would run the following command: '#{args.join(' ')}'") if Env.pretend?

    _stdout, stderr, status = Open3.capture3(*args)
    return true if status.success?

    err_line = stderr.to_s.split("\n").first.to_s.strip
    MediaLibrarian.app.speaker.speak_up("mkvpropedit failed: #{err_line}. Run: #{args.join(' ')}")
    false
  end

  def self.mkv_audio_track_map(path)
    return [] unless system('command -v mkvmerge >/dev/null 2>&1')
    stdout, status = Open3.capture2('mkvmerge', '-J', path)
    return [] unless status.success?

    tracks = JSON.parse(stdout).fetch('tracks', [])
    tracks.filter_map do |track|
      next unless track['type'] == 'audio'
      properties = track.fetch('properties', {})
      {
        id: track['id'],
        lang: properties['language'].to_s.downcase,
        name: properties['track_name'].to_s,
        commentary: properties['flag_commentary']
      }
    end
  rescue JSON::ParserError
    []
  end
end

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

    selected_track_index = nil
    track_map.each do |audio|
      next unless valid_audio.call(audio)
      lang = audio[:lang].to_s.strip.downcase

      track_lang = Languages.get_code(lang.split('-').first)
      next if track_lang.to_s == ''
      if track_lang == target_lang
        selected_track_index = audio[:audio_index]
        break
      end
    end

    return false unless selected_track_index

    args = ['mkvpropedit', path]
    track_map.each do |track|
      flag = (track[:audio_index] == selected_track_index) ? '1' : '0'
      args += ['--edit', "track:a#{track[:audio_index]}", '--set', "flag-default=#{flag}"]
    end
    return MediaLibrarian.app.speaker.speak_up("Would run the following command: '#{args.join(' ')}'") if Env.pretend?

    stdout, stderr, status = Open3.capture3(*args)
    combined_text = "#{stderr} #{stdout}".to_s
    if combined_text.match?(/Tracks/i) && combined_text.match?(/failed|échoué/i) && combined_text.match?(/unknown error|erreur inconnue/i)
      dir = File.dirname(path)
      tmp_path = File.join(dir, ".#{File.basename(path, '.*')}.remux#{File.extname(path)}")
      remux_out, remux_err, remux_status = Open3.capture3('mkvmerge', '-o', tmp_path, path)
      unless remux_status.success?
        MediaLibrarian.app.speaker.speak_up("mkvmerge remux failed: #{remux_err.to_s.strip} stdout: #{remux_out.to_s.strip} (mkvpropedit: #{combined_text.strip})")
        return false
      end
      tmp_args = args.dup
      tmp_args[1] = tmp_path
      tmp_out, tmp_err, tmp_status = Open3.capture3(*tmp_args)
      unless tmp_status.success?
        MediaLibrarian.app.speaker.speak_up("mkvpropedit failed on remuxed file: #{tmp_err.to_s.strip} stdout: #{tmp_out.to_s.strip} (mkvpropedit: #{combined_text.strip})")
        return false
      end
      FileUtils.mv(path, "#{path}.bak")
      FileUtils.mv(tmp_path, path)
    elsif !status.success?
      message = "mkvpropedit failed: #{stderr.to_s.strip}"
      stdout_line = stdout.to_s.strip
      message += " stdout: #{stdout_line}" unless stdout_line.empty?
      MediaLibrarian.app.speaker.speak_up("#{message}. Run: #{args.join(' ')}")
      return false
    end

    post_tracks = mkv_audio_track_map(path)
    if post_tracks.empty?
      MediaLibrarian.app.speaker.speak_up("Post-check failed: unable to read audio tracks via mkvmerge -J for #{path}.")
      return false
    end

    default_tracks = post_tracks.select { |track| %w[yes true 1].include?(track[:default].to_s.downcase) }
    if default_tracks.size != 1
      MediaLibrarian.app.speaker.speak_up("Post-check failed: expected 1 default audio track, found #{default_tracks.size} for #{path}.")
      return false
    end

    default_lang = Languages.get_code(default_tracks.first[:lang].to_s.split('-').first)
    if default_lang != target_lang
      MediaLibrarian.app.speaker.speak_up("Post-check failed: default audio language #{default_lang} does not match target #{target_lang} for #{path}.")
      return false
    end

    true
  end

  def self.mkv_audio_track_map(path)
    return [] unless system('command -v mkvmerge >/dev/null 2>&1')
    stdout, status = Open3.capture2('mkvmerge', '-J', path)
    return [] unless status.success?

    tracks = JSON.parse(stdout).fetch('tracks', [])
    audio_index = 0
    tracks.filter_map do |track|
      next unless track['type'] == 'audio'
      audio_index += 1
      properties = track.fetch('properties', {})
      edit_id = track['id'] || properties['number'] || properties['track_number']
      id_source = if track.key?('id')
                    "track['id']"
                  elsif properties.key?('number')
                    "properties['number']"
                  else
                    "properties['track_number']"
                  end
      MediaLibrarian.app.speaker.speak_up("mkv audio edit id from #{id_source}: #{edit_id}", 0) if Env.debug?
      next if edit_id.nil?
      {
        id: edit_id,
        audio_index: audio_index,
        lang: properties['language'].to_s.downcase,
        name: properties['track_name'].to_s,
        commentary: properties['flag_commentary'],
        default: properties['default_track']
      }
    end
  rescue JSON::ParserError
    []
  end
end

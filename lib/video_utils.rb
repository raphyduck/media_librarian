require 'json'
require 'open3'
require 'tmpdir'
require 'timeout'

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

  def self.set_default_original_audio!(path:, target_lang: nil)
    return MediaLibrarian.app.speaker.speak_up("Would set default original audio for #{path}") if Env.pretend?

    return false unless File.extname(path).downcase == '.mkv'
    return false unless system('command -v mkvmerge >/dev/null 2>&1')
    track_map = mkv_audio_track_map(path)
    return false if track_map.empty?
    target_lang = Languages.get_code(target_lang.to_s.split('-').first)
    return false if target_lang.to_s == ''
    if Env.debug?
      track_langs = track_map.map { |track| track[:lang].to_s.strip.downcase }.reject(&:empty?)
      MediaLibrarian.app.speaker.speak_up("Audio tracks for #{path}: #{track_langs.join(', ')}", 0)
    end
    default_tracks = track_map.select { |track| %w[yes true 1].include?(track[:default].to_s.downcase) }
    default_track = default_tracks.size == 1 ? default_tracks.first : nil
    default_lang = default_track ? Languages.get_code(default_track[:lang].to_s.split('-').first) : nil
    if default_track && default_lang == target_lang
      MediaLibrarian.app.speaker.speak_up("Default audio track #{default_track[:id]} already set to #{target_lang} for #{path}.")
      return true
    end
    if default_tracks.empty?
      first_lang = Languages.get_code(track_map.first[:lang].to_s.split('-').first)
      return true if first_lang == target_lang
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

    args = []
    track_map.each do |track|
      flag = (track[:audio_index] == selected_track_index) ? 'yes' : 'no'
      args += ['--default-track', "#{track[:id]}:#{flag}"]
    end
    args << path
    return MediaLibrarian.app.speaker.speak_up("Would run the following command: '#{args.join(' ')}'") if Env.pretend?
    MediaLibrarian.app.speaker.speak_up("Setting default audio track to #{selected_track_index} for #{path} with target language #{target_lang} using mkvmerge. Running command: #{args.join(' ')}") if Env.debug?
    result = process_mkv(path, tool: 'mkvmerge', args: args)
    unless result[:success]
      message = "mkvmerge remux failed: #{result[:stderr].to_s.strip}"
      stdout_line = result[:stdout].to_s.strip
      message += " stdout: #{stdout_line}" unless stdout_line.empty?
      message += " #{result[:message]}" if result[:message]
      MediaLibrarian.app.speaker.speak_up("#{message}. Run: mkvmerge #{args.join(' ')}")
      return false
    end
    post_tracks = mkv_audio_track_map(path)
    if post_tracks.empty?
      MediaLibrarian.app.speaker.speak_up("Remux integrity check failed: no audio tracks found for #{path}. Backup kept for manual recovery.")
      return false
    end
    post_defaults = post_tracks.select { |track| %w[yes true 1].include?(track[:default].to_s.downcase) }
    if post_defaults.size != 1
      MediaLibrarian.app.speaker.speak_up("Post-check failed: expected 1 default audio track, found #{post_defaults.size} for #{path}.")
      return false
    end

    post_lang = Languages.get_code(post_defaults.first[:lang].to_s.split('-').first)
    if post_lang != target_lang
      MediaLibrarian.app.speaker.speak_up("Post-check failed: default audio language #{post_lang} does not match target #{target_lang} for #{path}.")
      return false
    end
    MediaLibrarian.app.speaker.speak_up("Default audio track set to #{selected_track_index} for #{path} with target language #{target_lang}. Command returned #{result[:stdout]}")
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

  def self.process_mkv(path_source, tool:, args:, temp_dir: '/tmp', backup: true, timeout_s: nil)
    work_dir = Dir.mktmpdir('mkv_process_', temp_dir)
    ext = File.extname(path_source)
    input_local = File.join(work_dir, "input#{ext}")
    FileUtils.cp(path_source, input_local)
    args_local = args.map { |arg| arg == path_source ? input_local : arg }
    tmp_out = input_local
    if tool.to_s == 'mkvmerge'
      tmp_out = File.join(work_dir, "output#{ext}")
      args_local = replace_mkvmerge_output(args_local, tmp_out)
    end

    stdout, stderr, status = run_command(tool, args_local, timeout_s)
    return { success: false, stdout: stdout, stderr: stderr, message: 'command failed' } unless status&.success?
    return { success: false, stdout: stdout, stderr: stderr, message: 'validation failed' } unless mkv_validate_local(tmp_out)

    dir = File.dirname(path_source)
    dest_tmp = File.join(dir, ".#{File.basename(path_source)}.processing")
    FileUtils.cp(tmp_out, dest_tmp)
    bak_path = "#{path_source}.bak"
    FileUtils.mv(path_source, bak_path) if backup
    FileUtils.mv(dest_tmp, path_source)
    FileUtils.rm_f(bak_path) if backup
    { success: true, stdout: stdout, stderr: stderr }
  ensure
    FileUtils.rm_rf(work_dir) if work_dir && Dir.exist?(work_dir)
  end

  def self.replace_mkvmerge_output(args, tmp_out)
    replaced = false
    output_args = []
    args.each_with_index do |arg, idx|
      if %w[-o --output].include?(arg) && args[idx + 1]
        output_args << arg << tmp_out
        replaced = true
      elsif idx.positive? && %w[-o --output].include?(args[idx - 1])
        next
      else
        output_args << arg
      end
    end
    replaced ? output_args : ['-o', tmp_out] + args
  end

  def self.run_command(tool, args, timeout_s)
    if timeout_s
      Timeout.timeout(timeout_s) { Open3.capture3(tool, *args) }
    else
      Open3.capture3(tool, *args)
    end
  rescue Timeout::Error
    [''.dup, "timeout after #{timeout_s}s", nil]
  end

  def self.mkv_validate_local(path)
    if system('command -v mkvmerge >/dev/null 2>&1')
      _stdout, status = Open3.capture2('mkvmerge', '-J', path)
      return status.success?
    end
    return false unless system('command -v mkvinfo >/dev/null 2>&1')

    _stdout, _stderr, status = Open3.capture3('mkvinfo', path)
    status.success?
  end
end

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

  # Sets the default audio track for an MKV file based on the target language.
  # @param path [String] Path to the MKV file
  # @param target_lang [String, nil] Target language code for the default audio track
  # @param wait_for_space [Boolean] If true, wait for disk space to become available; if false, return error immediately
  # @return [Boolean] true if successful, false otherwise
  def self.set_default_original_audio!(path:, target_lang: nil, wait_for_space: false)
    return MediaLibrarian.app.speaker.speak_up("Would set default original audio for #{path}") if Env.pretend?

    Utils.lock_block("set_default_original_audio_#{path}") do
      return false unless File.extname(path).downcase == '.mkv'
      return false unless command_available?('mkvmerge')
      return false unless File.exist?(path)

      file_size = File.size(path)
      temp_dir = MediaLibrarian.app.temp_dir
      source_dir = File.dirname(path)

      # Check available disk space before proceeding
      # process_mkv creates: 2 copies in temp_dir (input + output), 1 copy in source_dir (processing file)
      # Adding 20% safety margin
      space_check_result = check_space_for_operation(
        file_size: file_size,
        temp_dir: temp_dir,
        source_dir: source_dir,
        wait_for_space: wait_for_space
      )
      unless space_check_result[:success]
        MediaLibrarian.app.speaker.speak_up(space_check_result[:message])
        return false
      end

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
      result = process_mkv(path, tool: 'mkvmerge', args: args, temp_dir: temp_dir)
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
      FileUtils.rm_f(result[:backup_path]) if result[:backup_path]
      MediaLibrarian.app.speaker.speak_up("Default audio track set to #{selected_track_index} for #{path} with target language #{target_lang}. Command returned #{result[:stdout]}")
      true
    end
  end

  # Check if there's enough disk space for the MKV processing operation
  # @param file_size [Integer] Size of the source file in bytes
  # @param temp_dir [String] Path to the temporary directory
  # @param source_dir [String] Path to the source file directory
  # @param wait_for_space [Boolean] If true, wait for space; if false, return error immediately
  # @return [Hash] { success: Boolean, message: String }
  def self.check_space_for_operation(file_size:, temp_dir:, source_dir:, wait_for_space: false)
    safety_margin = 1.2 # 20% safety margin
    temp_copies = 2 # input + output in temp_dir
    source_copies = 1 # processing file in source_dir

    check_interval = 30 # seconds between space checks when waiting
    max_wait_time = 3600 # maximum wait time in seconds (1 hour)

    # Find existing paths for disk space check (directories may not exist yet)
    temp_check_path = existing_path_for_space_check(temp_dir)
    source_check_path = existing_path_for_space_check(source_dir)

    # Check if temp_dir and source_dir are on the same filesystem
    same_filesystem = same_filesystem?(temp_check_path, source_check_path)

    loop do
      if same_filesystem
        # Same filesystem: combine space requirements
        total_copies = temp_copies + source_copies
        required_space = (file_size * total_copies * safety_margin).to_i
        available, = FileUtils.get_disk_space(source_check_path)

        if available >= required_space
          return { success: true, message: 'Sufficient disk space available' }
        end

        error_message = "Insufficient disk space: need #{format_bytes(required_space)}, have #{format_bytes(available)} (temp_dir and source_dir on same filesystem)"
      else
        # Different filesystems: check each separately
        required_temp_space = (file_size * temp_copies * safety_margin).to_i
        required_source_space = (file_size * source_copies * safety_margin).to_i

        temp_available, = FileUtils.get_disk_space(temp_check_path)
        source_available, = FileUtils.get_disk_space(source_check_path)

        temp_ok = temp_available >= required_temp_space
        source_ok = source_available >= required_source_space

        if temp_ok && source_ok
          return { success: true, message: 'Sufficient disk space available' }
        end

        error_parts = []
        error_parts << "temp_dir (#{temp_dir}): need #{format_bytes(required_temp_space)}, have #{format_bytes(temp_available)}" unless temp_ok
        error_parts << "source_dir (#{source_dir}): need #{format_bytes(required_source_space)}, have #{format_bytes(source_available)}" unless source_ok
        error_message = "Insufficient disk space for operation: #{error_parts.join('; ')}"
      end

      unless wait_for_space
        return { success: false, message: error_message }
      end

      MediaLibrarian.app.speaker.speak_up("#{error_message}. Waiting for space to become available...")
      sleep(check_interval)
      max_wait_time -= check_interval

      if max_wait_time <= 0
        return { success: false, message: "Timed out waiting for disk space: #{error_message}" }
      end
    end
  end

  # Find an existing path for disk space check by walking up parent directories
  # @param path [String] Path that may or may not exist
  # @return [String] The path itself if it exists, or the nearest existing parent directory
  def self.existing_path_for_space_check(path)
    current = path
    while current && current != '/' && current != '.'
      return current if File.exist?(current)
      current = File.dirname(current)
    end
    File.exist?(current) ? current : '/'
  end

  # Check if two paths are on the same filesystem (or should be treated as such)
  # @param path1 [String] First path
  # @param path2 [String] Second path
  # @return [Boolean] true if both paths are on the same filesystem or if either is on mergerfs
  def self.same_filesystem?(path1, path2)
    # If either path is on mergerfs, treat as same filesystem since mergerfs
    # writes to the underlying local filesystem first
    return true if mergerfs_path?(path1) || mergerfs_path?(path2)

    File.stat(path1).dev == File.stat(path2).dev
  rescue SystemCallError
    false
  end

  # Check if a path is mounted on a mergerfs filesystem
  # @param path [String] Path to check
  # @return [Boolean] true if the path is on a mergerfs mount
  def self.mergerfs_path?(path)
    return false unless File.exist?('/proc/mounts')

    real_path = File.realpath(path) rescue path
    mounts = File.read('/proc/mounts').lines.map do |line|
      parts = line.split
      { mount_point: parts[1], fs_type: parts[2] }
    end

    # Sort by mount point length descending to find the most specific mount
    mounts.sort_by { |m| -m[:mount_point].length }.each do |mount|
      if real_path.start_with?(mount[:mount_point] + '/') || real_path == mount[:mount_point]
        return mount[:fs_type] == 'fuse.mergerfs'
      end
    end

    false
  rescue SystemCallError, IOError
    false
  end

  # Format bytes to human-readable string
  # @param bytes [Integer] Size in bytes
  # @return [String] Human-readable size string
  def self.format_bytes(bytes)
    units = ['B', 'KB', 'MB', 'GB', 'TB']
    unit_index = 0
    size = bytes.to_f
    while size >= 1024 && unit_index < units.length - 1
      size /= 1024
      unit_index += 1
    end
    "%.2f %s" % [size, units[unit_index]]
  end

  def self.mkv_audio_track_map(path)
    return [] unless command_available?('mkvmerge')
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

  def self.process_mkv(path_source, tool:, args:, temp_dir: '/tmp', backup: true, timeout_s: nil, dry_run: false)
    log = lambda { |msg| MediaLibrarian.app.speaker.speak_up(msg) }
    return { success: false, message: "source file not found: #{path_source}" } unless File.file?(path_source)
    if tool.to_s == 'mkvmerge' && !dry_run && !command_available?('mkvmerge')
      log.call('mkvmerge not available in PATH')
      return { success: false, message: 'mkvmerge not available in PATH' }
    end

    dir = File.dirname(path_source)
    base = File.basename(path_source)
    lock_path = File.join(dir, ".#{base}.lock")
    dest_tmp = File.join(dir, ".#{base}.processing")
    work_dir = nil
    lock = nil
    lock_created = false
    source_size = File.size(path_source)
    work_dir = File.join(temp_dir, "mkvfix-#{Process.pid}-#{Time.now.to_i}")
    log.call("mkv temp dir: #{work_dir}")
    log.call("run #{tool} argv: #{([tool] + args).join(' ')}")
    if dry_run
      log.call("dry_run: would lock #{lock_path}, copy to #{work_dir}, write #{dest_tmp}, and update #{path_source}")
      return { success: true, dry_run: true }
    end
    begin
      lock = File.open(lock_path, File::WRONLY | File::CREAT | File::EXCL)
      lock_created = true
      lock.write("#{Process.pid}\n")
      lock.flush

      FileUtils.mkdir_p(work_dir, mode: 0o700)

      ext = File.extname(path_source)
      input_local = File.join(work_dir, "input#{ext}")
      log.call("copy source -> tmp: #{path_source} -> #{input_local}")
      FileUtils.cp(path_source, input_local)
      copied = File.size?(input_local).to_i
      return { success: false, message: "copy failed: expected #{source_size} bytes, got #{copied}" } if copied < source_size

      args_local = args.map { |arg| arg == path_source ? input_local : arg }
      tmp_out = input_local
      if tool.to_s == 'mkvmerge'
        tmp_out = File.join(work_dir, "output#{ext}")
        args_local = replace_mkvmerge_output(args_local, tmp_out)
      end
      log.call("run #{tool} argv: #{([tool] + args_local).join(' ')}")
      stdout, stderr, status = run_command(tool, args_local, timeout_s)
      log.call("stdout: #{stdout.to_s.lines.first(10).join.strip}")
      log.call("stderr: #{stderr.to_s.lines.first(10).join.strip}")
      return { success: false, stdout: stdout, stderr: stderr, message: 'command failed' } unless status&.success?
      return { success: false, stdout: stdout, stderr: stderr, message: 'validation failed' } unless mkv_validate_local(tmp_out)
      return { success: false, stdout: stdout, stderr: stderr, message: 'empty output' } unless File.size?(tmp_out)

      log.call("copy tmp -> dest_tmp: #{tmp_out} -> #{dest_tmp}")
      FileUtils.cp(tmp_out, dest_tmp)
      copied_out = File.size?(dest_tmp).to_i
      return { success: false, stdout: stdout, stderr: stderr, message: "dest copy failed: #{copied_out} bytes" } if copied_out < File.size(tmp_out)
      bak_path = "#{path_source}.bak"
      FileUtils.mv(path_source, bak_path) if backup
      begin
        File.rename(dest_tmp, path_source)
      rescue StandardError => e
        log.call("rename failed: #{e.message}, fallback to copy")
        FileUtils.cp(dest_tmp, path_source)
        FileUtils.rm_f(dest_tmp)
      end
      { success: true, stdout: stdout, stderr: stderr, backup_path: backup ? bak_path : nil }
    rescue Errno::EEXIST
      return { success: false, message: "lock exists: #{lock_path}" }
    ensure
      FileUtils.rm_f(dest_tmp)
      FileUtils.rm_rf(work_dir) if work_dir && Dir.exist?(work_dir)
      lock.close if lock
      FileUtils.rm_f(lock_path) if lock_created
    end
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
    return Open3.capture3(tool, *args) unless timeout_s

    stdout = ''.dup
    stderr = ''.dup
    status = nil
    Open3.popen3(tool, *args) do |stdin, out, err, wait|
      stdin.close
      out_thread = Thread.new { stdout << out.read.to_s }
      err_thread = Thread.new { stderr << err.read.to_s }
      begin
        Timeout.timeout(timeout_s) { status = wait.value }
      rescue Timeout::Error
        pid = wait.pid
        Process.kill('TERM', pid) rescue nil
        Process.kill('KILL', pid) rescue nil
        out_thread.join
        err_thread.join
        return [stdout, "timeout after #{timeout_s}s", nil]
      ensure
        out_thread.join
        err_thread.join
      end
    end
    [stdout, stderr, status]
  end

  def self.mkv_validate_local(path)
    if command_available?('mkvmerge')
      _stdout, status = Open3.capture2('mkvmerge', '-J', path)
      return status.success?
    end
    return false unless command_available?('mkvinfo')

    _stdout, _stderr, status = Open3.capture3('mkvinfo', path)
    status.success?
  end

  def self.command_available?(cmd)
    return false if cmd.to_s.strip.empty?
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
      next false if dir.empty?
      path = File.join(dir, cmd)
      File.file?(path) && File.executable?(path)
    end
  end
end

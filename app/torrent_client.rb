class TorrentClient

  def initialize
    init
    @tname = ''
    @throttled = false
    @already_listening = false
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    raise
  end

  def authenticate
    Utils.lock_block("deluge_daemon_init") do
      return if @deluge_connected
      @deluge.close rescue nil
      @deluge.connect
      @deluge_connected = 1
      listen
    end
  end

  def delete_torrent(tname, tid = '', remove_opts = 0, delete_status = -1)
    $t_client.remove_torrent(tid, true) if tid.to_s != '' rescue nil
    $db.update_rows('torrents', {:status => delete_status}, {:name => tname})
    Cache.queue_state_remove('deluge_options', tname) if remove_opts.to_i > 0
  end

  def disconnect
    @deluge.close
    @deluge_connected = nil
  end

  def download_file(download, options = {}, meta_id = '')
    options.select! { |key, _| [:move_completed, :main_only].include?(key) }
    options = Utils.recursive_typify_keys(options, 0) if options.is_a?(Hash)
    if options['move_completed'].to_s != ''
      options['move_completed_path'] = options['move_completed']
      options['move_completed'] = true
    end
    options['add_paused'] = true unless download[:type] > 1
    case download[:type]
    when 1
      $t_client.add_torrent_file(download[:filename], Base64.encode64(download[:file]), options)
      if meta_id.to_s != ''
        status = $t_client.get_torrent_status(meta_id, ['name', 'progress', 'queue'])
        raise 'Download failed' if status.nil? || status.empty?
        $t_client.queue_top(meta_id) if status['queue'].to_i > 1
      end
    when 2
      $t_client.add_torrent_magnet(download[:url], options)
    when 3
      $t_client.add_torrent_url(download[:url], options)
    end
  rescue => e
    if meta_id.to_s != '' && download.is_a?(Hash) && download[:type].to_i == 1
      status = $t_client.get_torrent_status(meta_id, ['name', 'progress'])
      raise e if status.nil? || status.empty?
    else
      raise e
    end
  end

  def find_main_file(status, whitelisted_exts = [])
    files = {}
    status['files'].each do |file|
      if FileUtils.get_extension(file['path']).match(/r(ar|\d{2})/)
        fname = file['path'].gsub(FileUtils.get_extension(file['path']), '')
      elsif whitelisted_exts.empty? || whitelisted_exts.include?(FileUtils.get_extension(file['path']))
        fname = file['path']
      else
        $speaker.speak_up "The file '#{file['path']}' is not on the allowed extension list (#{whitelisted_exts.join(', ')}), will not be included" if Env.debug?
        fname = 'illegalext'
      end
      files[fname] = {:s => 0, :f => []} unless files[fname]
      files[fname][:s] += file['size'].to_i
      files[fname][:f] << file['path']
    end
    files.select { |k, f| k != 'illegalext' && f[:s] > 0.8 * status['total_size'].to_i }.map { |_, v| v[:f] }.flatten
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    []
  end

  def init
    Utils.lock_block("deluge_daemon_init") do
      @deluge = Deluge::Rpc::Client.new(
          host: $config['deluge']['host'], port: 58846,
          login: $config['deluge']['username'], password: $config['deluge']['password']
      )
      @deluge_connected = nil
    end
  end

  def listen
    return if @already_listening
    @deluge.register_event('TorrentAddedEvent') do |torrent_id|
      $speaker.speak_up "Torrent #{torrent_id} was successfully added!"
      Cache.queue_state_add_or_update('deluge_torrents_added', torrent_id) if torrent_id.to_s != ''
    end
    @already_listening = true
  end

  def main_file_only(status, main_files)
    priorities = []
    main_files = [main_files] unless main_files.is_a?(Array)
    status['files'].map { |f| f['path'] }.each do |f|
      priorities << (main_files.include?(f) ? 1 : 0)
    end
    {'file_priorities' => priorities}
  end

  def parse_torrents_to_download
    $speaker.speak_up('Downloading torrent(s) added during the session (if any)', 0)
    $db.get_rows('torrents', {:status => 2}).each do |t|
      torrent = Cache.object_unpack(t[:tattributes])
      if Env.debug?
        $speaker.speak_up "#{LINE_SEPARATOR}\nTorrent attributes:"
        (torrent + t.select{|k,_| [:name, :identifiers].include?(k)}).each { |k, v| $speaker.speak_up "#{k} = #{v}" }
      end
      tdid = (Time.now.to_f * 1000).to_i.to_s
      @tname = t[:name]
      url = torrent[:torrent_link] ? torrent[:torrent_link] : ''
      magnet = torrent[:magnet_link]
      opts = {
          @tname => {
              :tdid => tdid,
              :move_completed => Utils.parse_filename_template(torrent[:move_completed].to_s, torrent),
              :rename_main => Utils.parse_filename_template(torrent[:rename_main].to_s, torrent),
              :queue => torrent[:queue].to_s,
              :assume_quality => torrent[:assume_quality],
              :entry_id => t[:identifiers].join,
              :added_at => Time.now.to_i,
              :category => torrent[:category]
          }
      }
      opts[@tname].merge!(torrent.select { |k, _| [:add_paused, :expect_main_file, :main_only, :whitelisted_extensions].include?(k) })
      Cache.queue_state_add_or_update('deluge_options', opts)
      path, ttype = nil, 1
      success = false
      tries = 5
      while (tries -= 1) >= 0 && !success
        $speaker.speak_up("Will download torrent '#{t[:name]}' on #{torrent[:tracker]}#{' (url = ' + url.to_s + ')' if url.to_s != ''}")
        if url.to_s != ''
          path = TorrentSearch.get_torrent_file(torrent[:tracker], tdid, url)
        elsif magnet.to_s != ''
          path, ttype = magnet, 2
        end
        success = process_download_torrent(ttype, path, opts[@tname], torrent[:tracker]) if path.to_s != ''
        $speaker.speak_up "Download of torrent '#{@tname}' #{success ? 'succeeded' : 'failed'}" if Env.debug? || !success
        if success
          Cache.queue_state_add_or_update('file_handling', {t[:identifier] => torrent[:files]}, 1, 1) if torrent[:files].is_a?(Array) && !torrent[:files].empty?
        end
        FileUtils.rm($temp_dir + "/#{tdid}.torrent") rescue nil
      end
    end
    @tname = ''
  end

  def process_added_torrents
    while Cache.queue_state_get('deluge_torrents_added').length != 0
      tid = Cache.queue_state_shift('deluge_torrents_added')
      tries = 10
      begin
        status = $t_client.get_torrent_status(tid, ['name', 'files', 'total_size', 'progress'])
        opts = Cache.queue_state_select('deluge_options') { |_, v| v && v[:info_hash] == tid }
        opts = Cache.queue_state_select('deluge_options') { |tn, _| tn == status['name'] } if opts.nil? || opts.empty?
        if opts.nil? || opts.empty?
          opts = Cache.queue_state_select('deluge_options') { |tn, _| $str_closeness.getDistance(tn[0..30], status['name'][0..30]) > 0.9 }
        end
        $speaker.speak_up("Processing added torrent #{status['name']} (tid '#{tid})'") unless (opts || {}).empty?
        (opts || {}).each do |tname, o|
          torrent_cache = $db.get_rows('torrents', {:name => tname}).first
          if torrent_cache && torrent_cache[:torrent_id].nil?
            $db.update_rows('torrents', {:torrent_id => tid}, {:name => tname})
          end
          set_options = {}
          main_file = find_main_file(status, o[:whitelisted_extensions] || [])
          if main_file.empty? && o[:expect_main_file].to_i > 0
            $speaker.speak_up "Torrent '#{torrent_cache[:name]}' (tid #{tid}) does not contain an archive or an acceptable file, removing" if Env.debug?
            delete_torrent(tname, tid)
            next
          end
          torrent_qualities = Quality.qualities_merge(tname, o[:assume_quality], o[:category]).split('.')
          set_options = main_file_only(status, main_file) if o[:main_only] && !main_file.empty?
          rename_torrent_files(tid, status['files'], o[:rename_main].to_s, torrent_qualities, o[:category])
          unless set_options.empty?
            $speaker.speak_up("Will set options: #{set_options}")
            $t_client.set_torrent_options([tid], set_options)
          end
          $t_client.queue_bottom([tid]) unless o[:queue].to_s == 'top' #Queue to bottom once all processed unless option to keep on top
          if o[:add_paused].to_i > 0
            $t_client.pause_torrent([tid])
          else
            $t_client.resume_torrent([tid])
          end
          Cache.queue_state_remove('deluge_options', tname)
        end
      rescue => e
        if !(tries -= 1).zero?
          sleep 30
          retry
        else
          $speaker.tell_error(e, Utils.arguments_dump(binding))
        end
      end
    end
  end

  def process_completed_torrents
    $speaker.speak_up("Will process completed torrents", 0) if Env.debug?
    Cache.queue_state_get('deluge_torrents_completed').each do |tid, data|
      t = $db.get_rows('torrents', {:torrent_id => tid}).first
      remove_it = 0
      begin
        if t.nil?
          $t_client.remove_torrent(tid, true) if $remove_torrent_on_completion
        else
          torrent = Cache.object_unpack(t[:tattributes])
          $speaker.speak_up("Processing torrent '#{t[:name]}' (tid '#{tid}')...",0) if Env.debug?
          target_seed_time = (TorrentSearch.get_tracker_config(torrent[:tracker])['seed_time'] || TorrentClient.get_config('deluge', 'default_seed_time') || 1).to_i
          seed_time = $t_client.get_torrent_status(tid, ['active_time'])['active_time'].to_i - data[:active_time].to_i
          if seed_time.nil?
            $speaker.speak_up "Torrent no longer exists, will remove now..." if Env.debug?
            remove_it = 1
          elsif target_seed_time <= seed_time.to_i / 3600
            $speaker.speak_up "Torrent has been seeding for #{seed_time.to_i / 3600} hours, more than the seed time set at #{target_seed_time} hour(s) for this tracker. Will remove now..." if Env.debug?
            $t_client.remove_torrent(tid, false) if $remove_torrent_on_completion && t[:status].to_i < 5
            $db.update_rows('torrents', {:status => [t[:status], 4].max}, {:name => t[:name]})
            remove_it = 1
          elsif Env.debug?
            $speaker.speak_up("Torrent has been seeding for #{seed_time.to_i / 3600} hours, less than the seed time set at #{target_seed_time} hour(s) for this tracker. Skipping...", 0)
          end
        end
      rescue => e
        if e.to_s == "InvalidTorrentError"
          $speaker.speak_up "Torrent no longer exists, removing from database..." if Env.debug?
          remove_it = 1
        else
          $speaker.tell_error(e, Utils.arguments_dump(binding))
        end
      end
      if remove_it > 0
        Cache.queue_state_remove('deluge_torrents_completed', tid)
        FileUtils.rm_r(data[:path]) if data[:path].to_s != '' && File.exists?(data[:path].to_s)
      end
    end
  end

  def process_download_torrent(torrent_type, path, opts, tracker = '')
    if torrent_type == 1
      file = File.open(path, "r")
      torrent = file.read
      file.close
      meta = BEncode.load(torrent, {:ignore_trailing_junk => 1})
      meta_id = Digest::SHA1.hexdigest(meta['info'].bencode)
      Cache.queue_state_add_or_update('deluge_options', {@tname => opts.merge({:info_hash => meta_id})})
      download = {:type => 1, :type_str => 'file', :file => torrent, :filename => File.basename(path)}
    else
      meta_id = opts[:tdid]
      download = {:type => 2, :type_str => 'magnet', :url => path}
    end
    $speaker.speak_up "Adding #{download[:type_str]} torrent #{@tname}"
    download_file(download, opts.deep_dup, meta_id)
    Cache.queue_state_add_or_update('deluge_torrents_added', meta_id) if meta_id.to_s != '' && torrent_type == 1
    $db.update_rows('torrents', {:status => 3, :torrent_id => meta_id}, {:name => @tname})
    true
  rescue => e
    Cache.queue_state_remove('deluge_options', @tname)
    $speaker.tell_error(
        e,
        "torrentclient.process_download_torrent('#{torrent_type}', '#{path}', '#{opts}', '#{tracker}')"
    )
    false
  end

  def rename_torrent_files(tid, files, new_dir_name, torrent_qualities = '', category = '')
    $speaker.speak_up("Will move all files in torrent in a directory '#{new_dir_name}', ensuring qualities #{torrent_qualities} in the filenames") if new_dir_name.to_s != ''
    paths = []
    files.each do |file|
      old_name = Quality.filename_quality_change(File.basename(file['path']), torrent_qualities, [], category)
      new_path = "#{new_dir_name.to_s + '/' if new_dir_name.to_s != ''}#{StringUtils.fix_encoding(old_name)}"
      paths << [file['index'], new_path]
    end
    $t_client.rename_files(tid, paths)
  end

  def method_missing(name, *args)
    tries ||= 3
    args = StringUtils.accents_clear(args)
    debug_str = "#{name}#{'(' + args.map { |a| DataUtils.format_string(a.to_s[0..100]) }.join(',') + ')' if args}"
    $speaker.speak_up("Running $t_client.#{debug_str}", 0) if Env.debug?
    return if Env.pretend? && !['get_torrent_status'].include?(name)
    result = nil
    Timeout.timeout(60) do
      authenticate
      if args.empty?
        result = eval("@deluge.core").method(name).call
      else
        result = eval("@deluge.core").method(name).call(*args)
      end
    end
    result
  rescue => e
    @deluge_connected = nil
    @deluge = nil #Nuke it, start over
    init
    if !(tries -= 1).zero?
      sleep 5
      retry
    else
      $speaker.tell_error(e, "$t_client.#{debug_str}")
      raise YAML.load(e.to_s)[0]
    end
  end

  def self.check_orphaned_torrent_folders(completed_folder:)
    ff = FileUtils.search_folder(completed_folder, {'maxdepth' => 1, 'dironly' => 1}).map { |f| File.basename(f[0]) }
    tids = $t_client.get_session_state
    tids.each do |tid|
      status = $t_client.get_torrent_status(tid, ['name', 'state'])
      ff.delete(status['name'])
    end
    ff.each do |f|
      $speaker.speak_up "Warning, folder '#{f}' is orphaned, will be removed"
      FileUtils.rm_r("#{completed_folder}/#{f}")
    end
  end

  def self.flush_queues
    if $t_client
      $t_client.parse_torrents_to_download
      sleep 15
      $t_client.process_added_torrents
      $t_client.process_completed_torrents
      $t_client.disconnect
    end
  end

  def self.get_config(client, key)
    $config[client][key] rescue nil
  end

  def self.monitor_torrent_client
    $speaker.speak_up("Checking free space remaining on torrent server", 0)
    free_space = $t_client.get_free_space / 1024 / 1024 / 1024
    $speaker.speak_up("Free space remaining: #{free_space}GB", 0)
    if free_space <= get_config('deluge', 'min_torrent_free_space').to_i && !@throttled
      $speaker.speak_up "There is only #{free_space}GB of free space on torrent server, will throttle download rate now!"
      $t_client.set_config({'config' => {'max_download_speed' => [get_config('deluge', 'max_download_rate').to_i / 100, 10].max}})
      @throttled = true
    elsif @throttled && free_space > get_config('deluge', 'min_torrent_free_space').to_i
      $speaker.speak_up "There is now enoough free space on torrent server, restoring full download speed!"
      $t_client.set_config({'config' => {'max_download_speed' => get_config('deluge', 'max_download_rate') || 1000}})
      @throttled = false
    end
  end

end
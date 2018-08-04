class TorrentClient

  def initialize
    @deluge = Deluge::Rpc::Client.new(
        host: $config['deluge']['host'], port: 58846,
        login: $config['deluge']['username'], password: $config['deluge']['password']
    )
    @deluge_connected = nil
    @tdid = 0
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    raise
  end

  def authenticate
    return if @deluge_connected
    @deluge.close rescue nil
    @deluge.connect
    @deluge_connected = 1
    listen
  end

  def disconnect
    @deluge.close
    @deluge_connected = nil
  end

  def download_file(download, options = {}, meta_id = '')
    options.select! {|key, _| [:move_completed, :rename_main, :main_only].include?(key)}
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
        status = $t_client.get_torrent_status(meta_id, ['name', 'progress'])
        raise 'Download failed' if status.nil? || status.empty?
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

  def find_main_file(status)
    files = {}
    status['files'].each do |file|
      if FileUtils.get_extension(file['path']).match(/r(ar|\d{2})/)
        fname = file['path'].gsub(FileUtils.get_extension(file['path']), '')
      else
        fname = file['path']
      end
      files[fname] = {:s => 0, :f => []} unless files[fname]
      files[fname][:s] += file['size'].to_i
      files[fname][:f] << file['path']
    end
    files.select {|_, f| f[:s] > 0.9 * status['total_size'].to_i}.map {|_, v| v[:f]}.flatten
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    []
  end

  def listen
    @deluge.register_event('TorrentAddedEvent') do |torrent_id|
      $speaker.speak_up "Torrent #{torrent_id} was successfully added!"
      Cache.queue_state_add_or_update('deluge_torrents_added', {torrent_id => 2})
    end
  end

  def main_file_only(status, main_files)
    priorities = []
    main_files = [main_files] unless main_files.is_a?(Array)
    status['files'].map {|f| f['path']}.each do |f|
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
        torrent.each {|k, v| $speaker.speak_up "#{k} = #{v}"}
      end
      @tdid = (Time.now.to_f * 1000).to_i
      url = torrent[:torrent_link] ? torrent[:torrent_link] : ''
      magnet = torrent[:magnet_link]
      path, ttype = nil, 1
      success = false
      tries = 5
      while (tries -= 1) >= 0 && !success
        $speaker.speak_up("Will download torrent '#{torrent[:name]}' on #{torrent[:tracker]}#{' (url = ' + url.to_s + ')' if url.to_s != ''}")
        if url.to_s != ''
          path = TorrentSearch.get_torrent_file(torrent[:tracker], @tdid, url)
        elsif magnet.to_s != ''
          path, ttype = magnet, 2
        end
        opts = {
            @tdid => {
                :t_name => torrent[:name],
                :move_completed => Utils.parse_filename_template(torrent[:move_completed].to_s, torrent),
                :rename_main => Utils.parse_filename_template(torrent[:rename_main].to_s, torrent),
                :main_only => torrent[:main_only].to_i,
                :add_paused => (torrent[:add_paused].to_s == 'true' || torrent[:add_paused].to_i == 1),
                :entry_id => torrent[:identifiers].join,
                :expect_main_file => torrent[:expect_main_file]
            }
        }
        Cache.queue_state_add_or_update('deluge_options', opts)
        success = process_download_torrent(ttype, path, opts[@tdid], torrent[:tracker]) if path.to_s != ''
        $speaker.speak_up "Download of torrent '#{torrent[:name]}' #{success ? 'succeeded' : 'failed'}" if Env.debug? || !success
        if success
          if torrent[:files].is_a?(Array) && !torrent[:files].empty?
            torrent[:files].each do |f|
              Cache.queue_state_add_or_update('dir_to_delete', {f[:name] => @tdid}) if f[:type] == 'file'
              TraktAgent.list_cache_add(f[:trakt_list], f[:trakt_type], f[:trakt_obj], @tdid) if f[:type] == 'trakt'
            end
          end
        end
        File.delete($temp_dir + "/#{@tdid}.torrent") rescue nil
      end
      unless success
        $db.update_rows('torrents', {:status => -1}, {:name => t[:name]})
        if torrent[:tracker].to_s != ''
          TorrentSearch.launch_search(torrent[:tracker], '').init rescue nil
        end
      end
    end
  end

  def process_added_torrents
    return if Env.pretend?
    @tdid = 0
    processed_torrent_id = {}
    return if Env.pretend?
    while Cache.queue_state_get('deluge_torrents_added').length != 0
      tid = Cache.queue_state_shift('deluge_torrents_added')
      next if tid[1].to_i < 2
      tid = tid[0]
      next if tid.to_s == ''
      processed_torrent_id[tid] ||= 0
      next if (processed_torrent_id[tid] += 1) > 60
      begin
        status = $t_client.get_torrent_status(tid, ['name', 'files', 'total_size', 'progress'])
        $speaker.speak_up("Processing added torrent #{status['name']}")
        opts = Cache.queue_state_select('deluge_options') {|_, v| v[:info_hash] == tid}
        opts = Cache.queue_state_select('deluge_options') {|_, v| v[:t_name] == status['name']} if opts.nil?
        if opts.nil? || opts.empty?
          opts = Cache.queue_state_select('deluge_options') {|_, v| $str_closeness.getDistance(v[:t_name][0..30], status['name'][0..30]) > 0.9}
        end
        (opts || {}).each do |did, o|
          torrent_cache = $db.get_rows('torrents', {:name => o[:t_name]}).first
          if torrent_cache && torrent_cache[:torrent_id].nil?
            $db.update_rows('torrents', {:torrent_id => tid}, {:name => torrent_cache[:name]})
          end
          set_options = {}
          if (o[:rename_main] && o[:rename_main] != '') || (o[:main_only] && o[:main_only].to_i > 0)
            main_file = find_main_file(status)
            if !main_file.empty?
              set_options = main_file_only(status, main_file) if o[:main_only]
              rename_main_file(tid, status['files'], o[:rename_main]) if o[:rename_main] && o[:rename_main] != ''
            elsif o[:expect_main_file].to_i > 0
              $speaker.speak_up "Torrent '#{torrent_cache[:name]}' (tid #{tid}) is split in multiple files and not an archive, removing" if Env.debug?
              $t_client.remove_torrent(tid, true) rescue nil
            end
          end
          unless set_options.empty?
            $t_client.set_torrent_options([tid], set_options)
            $speaker.speak_up("Will set options: #{set_options}")
          end
          Cache.queue_state_remove('deluge_options', did)
          $t_client.queue_bottom([tid]) #Queue to bottom once all processed
          $t_client.resume_torrent([tid]) unless o[:add_paused].to_i > 0
        end
      rescue => e
        $speaker.tell_error(e, "TorrentClient.process_added_torrents") if processed_torrent_id[tid].to_i > 60
        sleep 30
      end
    end
  end

  def process_download_torrent(torrent_type, path, opts, tracker = '')
    return true if Env.pretend?
    t_name = opts[:t_name]
    if torrent_type == 1
      file = File.open(path, "r")
      torrent = file.read
      file.close
      meta = BEncode.load(torrent, {:ignore_trailing_junk => 1})
      meta_id = Digest::SHA1.hexdigest(meta['info'].bencode)
      Cache.queue_state_add_or_update('deluge_options', {@tdid => opts.merge({:info_hash => meta_id})})
      $speaker.speak_up "Adding file torrent #{t_name}"
      download = {:type => 1, :file => torrent, :filename => File.basename(path)}
      Cache.queue_state_add_or_update('deluge_torrents_added', {meta_id => 2})
    else
      meta_id = @tdid
      $speaker.speak_up "Adding magnet torrent #{t_name}"
      download = {:type => 2, :url => path}
    end
    download_file(download, opts.deep_dup, meta_id)
    $db.update_rows('torrents', {:status => 3, :torrent_id => meta_id}, {:name => t_name})
    true
  rescue => e
    $speaker.tell_error(
        e,
        "torrentclient.process_download_torrent('#{torrent_type}', '#{path}', '#{opts}', '#{tracker}')"
    )
    false
  end

  def rename_main_file(tid, files, new_dir_name)
    $speaker.speak_up("Will move all files in torrent in a directory '#{new_dir_name}'.")
    paths = []
    files.each do |file|
      old_name = File.basename(file['path'])
      new_path = new_dir_name + '/' + old_name
      paths << [file['index'], new_path]
    end
    $t_client.rename_files(tid, paths)
  end

  def method_missing(name, *args)
    tries ||= 3
    authenticate
    if args.empty?
      eval("@deluge.core").method(name).call
    else
      eval("@deluge.core").method(name).call(*args)
    end
  rescue => e
    @deluge_connected = nil
    if !(tries -= 1).zero?
      sleep 3
      retry
    else
      $speaker.tell_error(e, "TorrentClient.#{name}#{'(' + args.map {|a| a.to_s[0..100]}.join(',') + ')' if args}")
      if @tdid.to_i > 0
        TraktAgent.list_cache_remove(@tdid)
        Cache.queue_state_select('dir_to_delete', 1) {|_, v| v != @tdid}
      end
      raise 'Lost connection'
    end
  end

end